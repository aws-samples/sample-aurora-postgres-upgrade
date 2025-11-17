#!/bin/bash
##-------------------------------------------------------------------------------------
#
# Purpose: To upgrade Aurora PostgreSQL clusters with comprehensive automation
#
# Usage: ./aurora_psql_patch.sh [cluster-identifier] [next-engine-version] [PREUPGRADE|UPGRADE]
#        ./aurora_psql_patch.sh aurora-cluster-test-1 15.6 PREUPGRADE
#        ./aurora_psql_patch.sh aurora-cluster-test-1 15.6 UPGRADE
#
#           PREUPGRADE = Run pre-requisite tasks, and do NOT run upgrade tasks
#           UPGRADE = Do not run pre-requisite tasks, but run upgrade tasks
#
# Note: 
#       1. Review this document [https://docs.aws.amazon.com/AmazonRDS/latest/AuroraUserGuide/AuroraPostgreSQL.Updates.html]
#          for appropriate minor or major supported version (a.k.a appropriate upgrade path) 
#       2. Parameter Group Behavior:
#          - MAJOR upgrades: Creates NEW cluster and instance parameter groups with target version family
#          - MINOR upgrades: Uses EXISTING parameter groups (no new parameter groups created)
#       3. Clone Safety Feature:
#          - UPGRADE operations: Creates copy-on-write clone BEFORE any database changes for fast rollback
#          - PREUPGRADE operations: No clone created (no database changes occur)
#          - Clone naming: {cluster-id}-clone-{timestamp} for uniqueness
#          - Rollback: Update connection strings to point to clone if upgrade fails
#       4. This script can be executed standalone, outside of SSM. It can also be integrated into CI/CD pipelines 
#          like CodeCommit, Jenkins, and other.
#       5. Standalone version has been tested, but it still needs to be tested thoroughly in your non-prod environment.
#       6. If running standalone, set SNS topic and S3 bucket name in the environment if email notification is required and
#          log files needs to be pushed and stored in S3 bucket. For e.g.:
#               export S3_BUCKET_PATCH_LOGS="aurora-psql-patch-test1-s3"
#               export SNS_TOPIC_ARN_EMAIL="arn:aws:sns:us-east-1:1234567890:aurora-psql-patch-test-sns-topic"
#
# Configuration:
#       Default behavior (can be overridden by environment variables):
#       - cluster_clone_required="Y"           # Creates copy-on-write clone before UPGRADE operations (both MAJOR and MINOR)
#       - cluster_snapshot_required="N"        # Creates manual snapshots for MINOR upgrades (both phases) and MAJOR upgrades (PREUPGRADE phase only)
#       - cluster_parameter_modify="N"         # Creates new parameter groups for MAJOR upgrades only (ignored for MINOR upgrades)
#       - instance_parameter_modify="N"        # Creates new instance parameter groups for MAJOR upgrades only (ignored for MINOR upgrades)
#       - cluster_drop_replication_slot="N"    # Automatically drop REPLICATION SLOTS during MAJOR upgrades only (manual handling required when N)
#       - S3_BUCKET_PATCH_LOGS=""              # S3 bucket for storing upgrade logs (empty by default)
#       - SNS_TOPIC_ARN_EMAIL=""               # SNS topic ARN for email notifications (empty by default)
#       - AWS_DEFAULT_REGION="us-west-2"       # AWS region for Aurora operations (us-west-2 by default)
#
#       Override configuration defaults by setting environment variables:
#               export cluster_clone_required="N"       # Disable copy-on-write clone creation before UPGRADE operations
#               export cluster_snapshot_required="N"     # Disable manual snapshots for all upgrades
#               export cluster_parameter_modify="Y"      # Create new parameter groups for MAJOR upgrades
#               export instance_parameter_modify="Y"     # Create new instance parameter groups for MAJOR upgrades
#               export cluster_drop_replication_slot="Y" # Auto-drop REPLICATION SLOTS for MAJOR upgrades
#               export S3_BUCKET_PATCH_LOGS="my-logs-bucket"  # Set S3 bucket for log storage
#               export SNS_TOPIC_ARN_EMAIL="arn:aws:sns:region:account:topic"  # Set SNS topic for notifications
#               export AWS_DEFAULT_REGION="us-east-1"    # Set AWS region
#
# Example Usage:
#        nohup ./aurora_psql_patch.sh aurora-cluster-test-1 15.6 PREUPGRADE >logs/pre-upgrade-aurora-cluster-test-1-`date +'%Y%m%d-%H-%M-%S'`.out 2>&1 &
#        nohup ./aurora_psql_patch.sh aurora-cluster-test-1 15.6 UPGRADE >logs/upgrade-aurora-cluster-test-1-`date +'%Y%m%d-%H-%M-%S'`.out 2>&1 &
#
# Prerequisites:
#     1. AWS Resources Required:
#        - EC2 instance for running this script
#        - IAM profile attached to EC2 instance with necessary permissions
#              * create_aurora_psql_patch_iam_policy_role_cfn.yaml can be used to create a policy and role. 
#                    ** Modify resource names appropriately
#              * Attach this IAM role to ec2 instance.
#        - Aurora PostgreSQL cluster with:
#              * VPC configuration
#              * Subnet group(s)
#              * Security group(s)
#              * Cluster and instance parameter groups
#              * Secrets Manager secret
#              * "create_aurora_psql_cluster_cfn.yaml" can be used (this creates cluster and instance parameter groups and Aurora cluster)
#                    ** Modify resource names appropriately
#        - AWS Secrets Manager secret attached to each Aurora cluster
#        - S3 bucket for upgrade logs
#        - SNS topic for notifications
#
#     2. Network Configuration:
#        - Aurora cluster security group must allow inbound traffic from EC2 instance
#
#     3. Required Tools:
#        - AWS CLI
#        - PostgreSQL client utilities
#        - jq for JSON processing
#        - bc (basic calculator) utility
#
#	   4. Update environment variables "manual" section if/as needed (optional)
#
# Functions:
#     wait_till_available_cluster - function to check Aurora cluster and instance status
#     create_cluster_param_group - function to create Aurora cluster parameter group (MAJOR upgrades only)
#     create_instance_param_group - function to create DB instance parameter group (MAJOR upgrades only)
#     cluster_upgrade - function to upgrade Aurora cluster
#     cluster_modify_logs - function to add Aurora cluster logs to CloudWatch
#     cluster_pending_maint - function to check pending maintenance status on cluster instances
#     get_aurora_creds - function to retrieve Aurora cluster creds from secret manager
#     copy_logs_to_s3 - copy upgrade files to s3 bucket for future reference
#     cluster_clone - function to create Aurora cluster copy-on-write clone before UPGRADE operations
#     cluster_snapshot - function to take Aurora cluster SNAPSHOT/backup if required
#     run_psql_command_aurora - run ANALYZE/VACUUM FREEZE commands on Aurora writer endpoint
#     run_psql_drop_repl_slot - check and drop REPLICATION SLOT in Aurora cluster if exists (applies to MAJOR VERSION UPGRADE only)
#     check_aurora_upgrade_type - function to determine if upgrade/patching path is MINOR or MAJOR
#     update_extensions - function to update PostgreSQL extensions on Aurora cluster
#     send_email - send email
#     get_aurora_cluster_info - get Aurora cluster related info into local variables
#     check_aurora_upgrade_version - check if the next-engine-version is valid for the current aurora-postgresql cluster version
#     check_db_name - function to check if db name is null. If null, DB related tasks will not apply
#     check_required_utils - function to check required utilities
#
##-------------------------------------------------------------------------------------

# Environment Variables - Input parameters #
current_cluster_id=${1}
next_engine_version=${2}

run_pre_upg_tasks=${3}
run_pre_upg_tasks=$(echo "${run_pre_upg_tasks}" | tr '[:lower:]' '[:upper:]')  # convert to upper case #

LOGS_DIR="./logs"

##-------------------------------------------------------------------------------------

# Environment Variables - Software binaries - Manual #
AWS_CLI=$(which aws)
PSQL_BIN=$(which psql)

# Environment Variables - Configuration (with defaults, can be overridden by environment) #
# 
# To override defaults, set environment variables before running the script:
#   export cluster_snapshot_required="N"     # Disable manual snapshots for all upgrades
#   export cluster_parameter_modify="Y"      # Create new parameter groups for MAJOR upgrades
#   export instance_parameter_modify="Y"     # Create new instance parameter groups for MAJOR upgrades
#   export cluster_drop_replication_slot="Y" # Auto-drop REPLICATION SLOTS for MAJOR upgrades
#   export S3_BUCKET_PATCH_LOGS="my-logs-bucket"  # Set S3 bucket for log storage
#   export SNS_TOPIC_ARN_EMAIL="arn:aws:sns:region:account:topic"  # Set SNS topic for notifications
#   export AWS_DEFAULT_REGION="us-east-1"    # Set AWS region
#
cluster_clone_required="${cluster_clone_required:-Y}"  # Default: Y - Create copy-on-write clone before UPGRADE operations (both MAJOR and MINOR)
cluster_snapshot_required="${cluster_snapshot_required:-N}"  # Default: N - Create manual snapshots for MINOR upgrades (both phases) and MAJOR upgrades (PREUPGRADE phase only)
cluster_parameter_modify="${cluster_parameter_modify:-N}"  # Default: N - Create new cluster parameter groups for MAJOR upgrades only (ignored for MINOR upgrades)
instance_parameter_modify="${instance_parameter_modify:-N}"  # Default: N - Create new instance parameter groups for MAJOR upgrades only (ignored for MINOR upgrades)
cluster_drop_replication_slot="${cluster_drop_replication_slot:-N}"  # Default: N - Automatically drop REPLICATION SLOTS during MAJOR upgrades only (manual handling required when N)

# AWS Environment Configuration
S3_BUCKET_PATCH_LOGS="${S3_BUCKET_PATCH_LOGS:-}"  # Default: empty - S3 bucket for storing upgrade logs (required for log storage)
SNS_TOPIC_ARN_EMAIL="${SNS_TOPIC_ARN_EMAIL:-}"  # Default: empty - SNS topic ARN for email notifications (required for notifications)
AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-west-2}"  # Default: us-west-2 - AWS region for Aurora operations

aurora_secret_tag_name="aurora-maintenance-user-secret"
aurora_secret_key_username="username"
aurora_secret_key_password="password"

DATE_TIME=$(date +'%Y%m%d-%H-%M-%S')

##-------------------------------------------------------------------------------------
# Essential logging functions (defined early to avoid "command not found" errors) #
##-------------------------------------------------------------------------------------

# Basic logging function for Aurora cluster context
function log_aurora_cluster_context() {
    local log_level="${1:-INFO}"
    local message="${2:-}"
    local operation="${3:-general}"
    local additional_context="${4:-}"
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${timestamp} ${log_level}: [Aurora-Cluster:${current_cluster_id:-unknown}] ${message}"
}

# Basic function to create Aurora log entries
function create_aurora_log_entry() {
    local operation="${1:-unknown}"
    local status="${2:-unknown}"
    local message="${3:-}"
    local metadata="${4:-}"
    local log_level="${5:-INFO}"
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    echo "${timestamp} ${log_level}: Aurora Log Entry - Operation: ${operation}, Status: ${status}, Message: ${message}"
}

##-------------------------------------------------------------------------------------

# Function to generate session summary on script exit
generate_aurora_exit_summary() {
    local exit_code="${1:-0}"
    local exit_status="success"
    local exit_details=""
    local notification_status=""
    local notification_details=""
    
    # Determine exit status and details based on exit code
    if [ "${exit_code}" -eq 0 ]; then
        exit_status="success"
        exit_details="Aurora PostgreSQL upgrade workflow completed successfully without errors."
        notification_status="SUCCESS"
        notification_details="Aurora upgrade completed successfully"
    else
        exit_status="error"
        exit_details="Aurora PostgreSQL upgrade workflow terminated with exit code ${exit_code}. Check error logs for details."
        notification_status="FAILED"
        notification_details="Aurora upgrade failed with exit code ${exit_code}. Check logs for details."
        
        # Log the exit error
        if [ -n "${current_cluster_id}" ]; then
            log_aurora_error "Script terminated with exit code ${exit_code}" "${exit_code}" "script_exit" "Review error logs and resolve issues before retrying" "script_termination"
        fi
    fi
    
    # Generate session summary if logging is available
    if [ -n "${LOGS_DIR}" ] && [ -n "${current_cluster_id}" ]; then
        generate_aurora_session_summary "${exit_status}" "${exit_details}"
    fi
    
    # Send status-based email notification
    send_email "${notification_status}" "${notification_details}"
}

# Set up trap to generate session summary on script exit
trap 'generate_aurora_exit_summary $?' EXIT

##-------------------------------------------------------------------------------------

# check number of input arguments #
if [ ! $# -eq 3 ]; then
    echo -e "\nERROR: Incorrect syntax; Three (3) parameters expected."
    echo -e "\nUsage: ./aurora_psql_patch.sh [cluster-identifier] [next-engine-version] [PREUPGRADE|UPGRADE]"
    echo -e "Example:"
    echo -e "       ./aurora_psql_patch.sh aurora-cluster-test-1 15.6 PREUPGRADE"
    echo -e "       ./aurora_psql_patch.sh aurora-cluster-test-1 15.6 UPGRADE\n"
    exit 1
fi

# validate 3rd argument/parameter #
if [ ! "${run_pre_upg_tasks}" = "PREUPGRADE" ] && [ ! "${run_pre_upg_tasks}" = "UPGRADE" ]; then
    echo -e "\nERROR: Invalid 3rd parameter. Expected value PREUPGRADE|UPGRADE."
    echo -e "\nUsage: ./aurora_psql_patch.sh [cluster-identifier] [next-engine-version] [PREUPGRADE|UPGRADE]"
    echo -e "Example:"
    echo -e "       ./aurora_psql_patch.sh aurora-cluster-test-1 15.6 PREUPGRADE"
    echo -e "       ./aurora_psql_patch.sh aurora-cluster-test-1 15.6 UPGRADE\n"
    exit 1
fi

# Display input parameters for verification
echo ""
log_aurora_cluster_context "INFO" "Input parameter 1 [Aurora Cluster ID]: $current_cluster_id" "initialization"
log_aurora_cluster_context "INFO" "Input parameter 2 [Requested Upgrade Engine Version]: $next_engine_version" "initialization"
log_aurora_cluster_context "INFO" "Input parameter 3 [Upgrade Option]: $run_pre_upg_tasks" "initialization"
echo ""

if [ "${run_pre_upg_tasks}" = "PREUPGRADE" ]; then
   EMAIL_SUBJECT="Aurora PostgreSQL PREUPGRADE Tasks"
else
   EMAIL_SUBJECT="Aurora PostgreSQL UPGRADE"
fi

echo -e "\nBEGIN -  ${EMAIL_SUBJECT} - $(date)"
log_aurora_cluster_context "INFO" "Starting Aurora PostgreSQL upgrade workflow: ${EMAIL_SUBJECT}" "workflow_start"
create_aurora_log_entry "workflow_start" "started" "Aurora PostgreSQL upgrade workflow initiated" "{\"email_subject\":\"${EMAIL_SUBJECT}\"}"

##-------------------------------------------------------------------------------------
# functions #
##-------------------------------------------------------------------------------------

# Function to check required utilities
check_required_utils() {
    local missing_utils=()
    
    # List of required utilities
    local utils=(
        "aws"
        "jq"
        "bc"
        "psql"
        "grep"
        "cut"
        "tr"
        "tee"
        "date"
        "which"
    )
    
    echo -e "\nINFO: Checking for required utilities...\n"
    for util in "${utils[@]}"; do
        if ! command -v "$util" >/dev/null 2>&1; then
            missing_utils+=("$util")
        fi
    done
    
    if [ ${#missing_utils[@]} -ne 0 ]; then
        echo "ERROR: The following required utilities are missing:"
        for util in "${missing_utils[@]}"; do
            echo "  - $util"
        done

        echo -e "\nERROR: Please install the missing utilities before running this script. \n"
        return 1
    fi
    
    echo -e "\nINFO: All required utilities are present. \n"
    return 0
}
##-------------------------------------------------------------------------------------

# function to check if db name is null. If null, DB related tasks will not apply.
function check_db_name() {
    local db_name="$1"
    
    if [ -z "${db_name}" ] || [ "${db_name}" = "null" ]; then
        echo -e "\nINFO: Database name is empty. Above step is not required. \n"
        return 1
    fi
    
    return 0
}
##-------------------------------------------------------------------------------------

# function to check Aurora cluster and instance status #
function wait_till_available_cluster() {
    local operation_type="${1:-upgrade}"  # upgrade, maintenance, reboot, snapshot
    local max_wait_minutes="${2:-120}"    # default 2 hours timeout
    
    echo -e "\nINFO: Execute wait_till_available_cluster function for ${operation_type} operation...\n"
    
    # Set operation-specific timeouts and wait intervals
    local wait_interval=60  # seconds between status checks
    local initial_wait=90   # initial wait before first check
    
    case "${operation_type}" in
        "upgrade")
            max_wait_minutes=180  # 3 hours for upgrades
            initial_wait=120      # longer initial wait for upgrades
            ;;
        "maintenance")
            max_wait_minutes=90   # 1.5 hours for maintenance
            initial_wait=60
            ;;
        "reboot")
            max_wait_minutes=30   # 30 minutes for reboots
            initial_wait=30
            ;;
        "snapshot")
            max_wait_minutes=60   # 1 hour for snapshots
            initial_wait=30
            ;;
        *)
            max_wait_minutes=120  # default 2 hours
            initial_wait=90
            ;;
    esac
    
    local max_wait_seconds=$((max_wait_minutes * 60))
    local elapsed_seconds=0
    
    echo "INFO: Waiting for Aurora ${operation_type} operation to complete..."
    echo "INFO: Maximum wait time: ${max_wait_minutes} minutes"
    echo "INFO: Initial wait: ${initial_wait} seconds"
    
    # Initial wait for operation to start
    sleep ${initial_wait}s
    elapsed_seconds=$((elapsed_seconds + initial_wait))
    
    # Get all cluster member instances for comprehensive monitoring
    local cluster_instances=$( ${AWS_CLI} rds describe-db-clusters --db-cluster-identifier ${current_cluster_id} --query 'DBClusters[0].DBClusterMembers[].DBInstanceIdentifier' --output text )
    local writer_instance_id=$( ${AWS_CLI} rds describe-db-clusters --db-cluster-identifier ${current_cluster_id} --query 'DBClusters[0].DBClusterMembers[?IsClusterWriter==`true`].DBInstanceIdentifier' --output text )
    
    echo "INFO: Monitoring cluster instances: ${cluster_instances}"
    echo "INFO: Writer instance: ${writer_instance_id}"
    
    # Debug: Check if writer instance is empty
    if [ -z "${writer_instance_id}" ]; then
        echo "WARNING: Writer instance identification returned empty - using alternative method"
        writer_instance_id=$( ${AWS_CLI} rds describe-db-clusters --db-cluster-identifier ${current_cluster_id} --query 'DBClusters[0].DBClusterMembers[?IsClusterWriter].DBInstanceIdentifier' --output text )
        echo "INFO: Alternative writer instance query result: ${writer_instance_id}"
    fi
    
    while [ ${elapsed_seconds} -lt ${max_wait_seconds} ]; do
        # Check cluster status
        current_cluster_status=$( ${AWS_CLI} rds describe-db-clusters --db-cluster-identifier ${current_cluster_id} --query 'DBClusters[0].Status' --output text | tr '[:lower:]' '[:upper:]' )
        
        # Check all instance statuses
        local all_instances_available=true
        local instance_status_summary=""
        
        for instance_id in ${cluster_instances}; do
            if [ -n "${instance_id}" ]; then
                local instance_status=$( ${AWS_CLI} rds describe-db-instances --db-instance-identifier ${instance_id} --query 'DBInstances[0].DBInstanceStatus' --output text | tr '[:lower:]' '[:upper:]' )
                
                if [ "${instance_status}" != "AVAILABLE" ]; then
                    all_instances_available=false
                fi
                
                # Build status summary with debugging
                if [ "${instance_id}" = "${writer_instance_id}" ]; then
                    instance_status_summary="${instance_status_summary}Writer(${instance_id}): ${instance_status} "
                else
                    instance_status_summary="${instance_status_summary}Reader(${instance_id}): ${instance_status} "
                fi
            fi
        done
        
        # Check if cluster and all instances are available
        if [ "${current_cluster_status}" = "AVAILABLE" ] && [ "${all_instances_available}" = "true" ]; then
            echo -e "\nINFO: Aurora cluster and all instances are now available."
            echo "INFO: Final cluster status: ${current_cluster_status}"
            echo "INFO: Final instance statuses: ${instance_status_summary}"
            echo "INFO: Total wait time: $((elapsed_seconds / 60)) minutes"
            return 0
        fi
        
        # Log current status
        echo "INFO: Wait-Aurora${operation_type} [${elapsed_seconds}s/${max_wait_seconds}s] Cluster: ${current_cluster_status} | Instances: ${instance_status_summary} - $(date)"
        
        # Handle error states
        case "${current_cluster_status}" in
            "FAILED"|"INCOMPATIBLE-PARAMETERS"|"INCOMPATIBLE-RESTORE"|"STORAGE-FULL")
                log_aurora_error "Aurora cluster is in error state: ${current_cluster_status}" "1" "${operation_type}" "Check Aurora cluster logs and resolve the issue before retrying" "cluster_error_state"
                exit 1
                ;;
        esac
        
        # Check for instance error states
        for instance_id in ${cluster_instances}; do
            if [ -n "${instance_id}" ]; then
                local instance_status=$( ${AWS_CLI} rds describe-db-instances --db-instance-identifier ${instance_id} --query 'DBInstances[0].DBInstanceStatus' --output text | tr '[:lower:]' '[:upper:]' )
                case "${instance_status}" in
                    "FAILED"|"INCOMPATIBLE-PARAMETERS"|"INCOMPATIBLE-RESTORE"|"STORAGE-FULL"|"INACCESSIBLE-ENCRYPTION-CREDENTIALS")
                        log_aurora_error "Aurora instance ${instance_id} is in error state: ${instance_status}" "1" "${operation_type}" "Check instance logs and resolve the issue before retrying" "instance_error_state"
                        exit 1
                        ;;
                esac
            fi
        done
        
        # Wait before next check
        sleep ${wait_interval}s
        elapsed_seconds=$((elapsed_seconds + wait_interval))
    done
    
    # Timeout reached
    log_aurora_error "Timeout reached waiting for Aurora ${operation_type} operation to complete. Maximum wait time of ${max_wait_minutes} minutes exceeded." "1" "${operation_type}" "Check Aurora cluster status and logs manually, then retry the operation" "operation_timeout"
    log_aurora_cluster_context "ERROR" "Current cluster status: ${current_cluster_status}" "${operation_type}" "Timeout"
    log_aurora_cluster_context "ERROR" "Current instance statuses: ${instance_status_summary}" "${operation_type}" "Timeout"
    exit 1
}
##-------------------------------------------------------------------------------------
# function to create Aurora cluster parameter group #
function create_cluster_param_group() {

   log_aurora_operation_start "create_cluster_param_group" "Creating Aurora cluster parameter group for ${current_engine_type}${next_engine_version_family}"
   return_value=""

   # generate new cluster parameter group name #
   cluster_param_group_name="aurora-cluster-param-group-${current_engine_type}${next_engine_version_family}-${current_cluster_id}"
   echo -e "\ncluster_param_group_name = $cluster_param_group_name\n"

   #echo "${AWS_CLI} rds describe-db-cluster-parameter-groups --db-cluster-parameter-group-name ${cluster_param_group_name} 2>/dev/null"
   ${AWS_CLI} rds describe-db-cluster-parameter-groups --db-cluster-parameter-group-name ${cluster_param_group_name} 2>/dev/null
   return_value="$?"
   echo ""
   echo "ClusterParamGroupCheck ReturnValue = ${return_value}"

   # get current cluster parameter group name #
   current_cluster_param_group=$( ${AWS_CLI} rds describe-db-clusters --db-cluster-identifier ${current_cluster_id} --query 'DBClusters[0].[DBClusterParameterGroup]' --output text )
   echo "current_cluster_param_group = $current_cluster_param_group"

   # if parameter group does NOT exists, then create a new one #
   if [ "${return_value}" = "0" ]; then

      log_aurora_cluster_context "INFO" "Aurora Cluster Parameter Group ${cluster_param_group_name} already exists" "create_cluster_param_group"
      log_aurora_operation_complete "create_cluster_param_group" "success" "Using existing cluster parameter group"

   else

        log_aurora_cluster_context "INFO" "Creating new Aurora cluster parameter group: ${cluster_param_group_name}" "create_cluster_param_group"

        # create new cluster parameter group #
        ${AWS_CLI} rds create-db-cluster-parameter-group \
                --db-cluster-parameter-group-name "${cluster_param_group_name}" \
                --db-parameter-group-family "${current_engine_type}${next_engine_version_family}" \
                --description "${current_engine_type}${next_engine_version_family} Aurora cluster parameter group for ${current_cluster_id} cluster" \
                --tags '[{"Key": "Name","Value": "'"$cluster_param_group_name"'"}]'

         return_value="$?"
	     echo ""
         echo "CreateClusterParamGroup ReturnValue = ${return_value}"
	      
         if [ "${return_value}" != "0" ]; then
              exit 1
         fi

     	if [ "${cluster_parameter_modify}" = "Y" ]; then

            echo -e "\nINFO: Modify Aurora cluster parameter group...\n"

            # Define parameters to modify #
            # only 20 parameters can be modified at a time; hence splitting into two groups #
            # These are security best practices related; also include enabling logical replication parameters as well #
            # These parameters can be removed or updated as needed #
            local cluster_params=(
                      "ParameterName=authentication_timeout,ParameterValue=300,ApplyMethod=immediate"
                      "ParameterName=backslash_quote,ParameterValue=safe_encoding,ApplyMethod=immediate"
                      "ParameterName=client_min_messages,ParameterValue=notice,ApplyMethod=immediate"
                      "ParameterName=escape_string_warning,ParameterValue=1,ApplyMethod=immediate"
                      "ParameterName=log_connections,ParameterValue=1,ApplyMethod=immediate"
                      "ParameterName=log_disconnections,ParameterValue=1,ApplyMethod=immediate"
                      "ParameterName=log_duration,ParameterValue=1,ApplyMethod=immediate"
                      "ParameterName=log_min_duration_statement,ParameterValue=1000,ApplyMethod=immediate"
                      "ParameterName=log_min_error_statement,ParameterValue=info,ApplyMethod=immediate"
                      "ParameterName=log_min_messages,ParameterValue=info,ApplyMethod=immediate"
                      "ParameterName=log_statement,ParameterValue=all,ApplyMethod=immediate"
                      "ParameterName=rds.logical_replication,ParameterValue=1,ApplyMethod=pending-reboot"
                      "ParameterName=shared_preload_libraries,ParameterValue=pg_stat_statements,ApplyMethod=pending-reboot"
                      "ParameterName=standard_conforming_strings,ParameterValue=1,ApplyMethod=immediate"
                      "ParameterName=tcp_keepalives_count,ParameterValue=0,ApplyMethod=immediate"
           )

           local cluster_params2=(
                       "ParameterName=tcp_keepalives_idle,ParameterValue=0,ApplyMethod=immediate"
                       "ParameterName=tcp_keepalives_interval,ParameterValue=0,ApplyMethod=immediate"
                       "ParameterName=rds.force_ssl,ParameterValue=0,ApplyMethod=immediate"
                       "ParameterName=rds.log_retention_period,ParameterValue=4320,ApplyMethod=immediate"
                       "ParameterName=wal_receiver_timeout,ParameterValue=0,ApplyMethod=immediate"
                       "ParameterName=wal_sender_timeout,ParameterValue=0,ApplyMethod=immediate"
                       "ParameterName=idle_in_transaction_session_timeout,ParameterValue=0,ApplyMethod=immediate"
                       "ParameterName=checkpoint_warning,ParameterValue=0,ApplyMethod=immediate"
                       "ParameterName=statement_timeout,ParameterValue=0,ApplyMethod=immediate"
           )

	   # modify 1st set of cluster parameters #
    	   ${AWS_CLI} rds modify-db-cluster-parameter-group --db-cluster-parameter-group-name "${cluster_param_group_name}" --parameters "${cluster_params[@]}"

           return_value="$?"
	   echo ""
           echo "ClusterParamGroupUpdate1 ReturnValue = ${return_value}"

           if [ "${return_value}" != "0" ]; then
                exit 1
           fi

	   # modify 2nd set of cluster parameters #
           ${AWS_CLI} rds modify-db-cluster-parameter-group --db-cluster-parameter-group-name "${cluster_param_group_name}" --parameters "${cluster_params2[@]}"

           return_value="$?"
	   echo ""
           echo "ClusterParamGroupUpdate2 ReturnValue = ${return_value}"

           if [ "${return_value}" != "0" ]; then
              exit 1
           fi

       fi

   fi

   log_aurora_operation_complete "create_cluster_param_group" "success" "Aurora cluster parameter group configuration completed"
   create_aurora_log_entry "create_cluster_param_group" "success" "Aurora cluster parameter group ready" "{\"parameter_group\":\"${cluster_param_group_name}\",\"family\":\"${current_engine_type}${next_engine_version_family}\"}"

}
##-------------------------------------------------------------------------------------

# function to create DB instance parameter group (for major upgrades only) #
function create_instance_param_group() {

   log_aurora_operation_start "create_instance_param_group" "Creating Aurora instance parameter group for ${current_engine_type}${next_engine_version_family}"
   return_value=""

   # generate new instance parameter group name #
   instance_param_group_name="aurora-instance-param-group-${current_engine_type}${next_engine_version_family}-${current_cluster_id}"
   echo -e "\ninstance_param_group_name = $instance_param_group_name\n"

   # get current instance parameter group name from writer instance #
   if [ -z "${current_instance_param_group}" ]; then
       current_instance_param_group=$( ${AWS_CLI} rds describe-db-instances --db-instance-identifier ${writer_instance_id} --query 'DBInstances[0].DBParameterGroups[0].DBParameterGroupName' --output text )
   fi
   echo "current_instance_param_group = $current_instance_param_group"

   ${AWS_CLI} rds describe-db-parameter-groups --db-parameter-group-name ${instance_param_group_name} 2>/dev/null
   return_value="$?"
   echo ""
   echo "InstanceParamGroupCheck ReturnValue = ${return_value}"

   # if parameter group does NOT exists, then create a new one #
   if [ "${return_value}" = "0" ]; then

      log_aurora_cluster_context "INFO" "Aurora Instance Parameter Group ${instance_param_group_name} already exists" "create_instance_param_group"
      log_aurora_operation_complete "create_instance_param_group" "success" "Using existing instance parameter group"

   else

        log_aurora_cluster_context "INFO" "Creating new Aurora instance parameter group: ${instance_param_group_name}" "create_instance_param_group"

        # create new instance parameter group #
        ${AWS_CLI} rds create-db-parameter-group \
                --db-parameter-group-name "${instance_param_group_name}" \
                --db-parameter-group-family "${current_engine_type}${next_engine_version_family}" \
                --description "${current_engine_type}${next_engine_version_family} Aurora instance parameter group for ${current_cluster_id} cluster" \
                --tags '[{"Key": "Name","Value": "'"$instance_param_group_name"'"}]'

         return_value="$?"
	     echo ""
         echo "CreateInstanceParamGroup ReturnValue = ${return_value}"
	      
         if [ "${return_value}" != "0" ]; then
              exit 1
         fi

     	if [ "${instance_parameter_modify}" = "Y" ]; then

            echo -e "\nINFO: Modify Aurora instance parameter group...\n"

            # Define instance-specific parameters to modify #
            # These are instance-level PostgreSQL parameters #
            local instance_params=(
                      "ParameterName=authentication_timeout,ParameterValue=300,ApplyMethod=immediate"
                      "ParameterName=client_min_messages,ParameterValue=notice,ApplyMethod=immediate"
                      "ParameterName=escape_string_warning,ParameterValue=1,ApplyMethod=immediate"
                      "ParameterName=log_connections,ParameterValue=1,ApplyMethod=immediate"
                      "ParameterName=log_disconnections,ParameterValue=1,ApplyMethod=immediate"
                      "ParameterName=log_duration,ParameterValue=1,ApplyMethod=immediate"
                      "ParameterName=log_min_duration_statement,ParameterValue=1000,ApplyMethod=immediate"
                      "ParameterName=log_min_error_statement,ParameterValue=info,ApplyMethod=immediate"
                      "ParameterName=log_min_messages,ParameterValue=info,ApplyMethod=immediate"
                      "ParameterName=log_statement,ParameterValue=all,ApplyMethod=immediate"
                      "ParameterName=shared_preload_libraries,ParameterValue=pg_stat_statements,ApplyMethod=pending-reboot"
                      "ParameterName=standard_conforming_strings,ParameterValue=1,ApplyMethod=immediate"
           )

           local instance_params2=(
                       "ParameterName=tcp_keepalives_count,ParameterValue=0,ApplyMethod=immediate"
                       "ParameterName=tcp_keepalives_idle,ParameterValue=0,ApplyMethod=immediate"
                       "ParameterName=tcp_keepalives_interval,ParameterValue=0,ApplyMethod=immediate"
                       "ParameterName=rds.log_retention_period,ParameterValue=4320,ApplyMethod=immediate"
                       "ParameterName=idle_in_transaction_session_timeout,ParameterValue=0,ApplyMethod=immediate"
                       "ParameterName=statement_timeout,ParameterValue=0,ApplyMethod=immediate"
           )

	   # modify 1st set of instance parameters #
    	   ${AWS_CLI} rds modify-db-parameter-group --db-parameter-group-name "${instance_param_group_name}" --parameters "${instance_params[@]}"

           return_value="$?"
	   echo ""
           echo "InstanceParamGroupUpdate1 ReturnValue = ${return_value}"

           if [ "${return_value}" != "0" ]; then
                exit 1
           fi

	   # modify 2nd set of instance parameters #
           ${AWS_CLI} rds modify-db-parameter-group --db-parameter-group-name "${instance_param_group_name}" --parameters "${instance_params2[@]}"

           return_value="$?"
	   echo ""
           echo "InstanceParamGroupUpdate2 ReturnValue = ${return_value}"

           if [ "${return_value}" != "0" ]; then
              exit 1
           fi

       fi

   fi

   log_aurora_operation_complete "create_instance_param_group" "success" "Aurora instance parameter group configuration completed"
   create_aurora_log_entry "create_instance_param_group" "success" "Aurora instance parameter group ready" "{\"parameter_group\":\"${instance_param_group_name}\",\"family\":\"${current_engine_type}${next_engine_version_family}\"}"

}
##-------------------------------------------------------------------------------------

# function to determine and validate parameter group assignment logic #
function determine_parameter_group_assignment() {
    echo -e "\nINFO: Execute determine_parameter_group_assignment function...\n"
    
    local upgrade_scope="${1:-${UPGRADE_SCOPE}}"
    local validation_only="${2:-false}"
    
    # Initialize parameter group assignment variables
    local use_cluster_param_group="true"
    local use_instance_param_group="false"
    local assignment_valid="true"
    local assignment_errors=()
    
    echo "INFO: Determining parameter group assignment for ${upgrade_scope} upgrade..."
    
    # Determine parameter group requirements based on upgrade scope
    case "${upgrade_scope}" in
        "MAJOR"|"major")
            use_cluster_param_group="true"
            use_instance_param_group="true"
            echo "INFO: MAJOR UPGRADE detected - both cluster and instance parameter groups required"
            ;;
        "MINOR"|"minor")
            use_cluster_param_group="true"
            use_instance_param_group="false"
            echo "INFO: MINOR UPGRADE detected - only cluster parameter group required"
            ;;
        *)
            assignment_errors+=("Invalid upgrade scope: ${upgrade_scope}")
            assignment_valid="false"
            ;;
    esac
    
    # Validate cluster parameter group if required
    if [ "${use_cluster_param_group}" = "true" ]; then
        if [ -z "${cluster_param_group_name}" ]; then
            assignment_errors+=("Cluster parameter group name is not set")
            assignment_valid="false"
        else
            # Check if cluster parameter group exists
            if ! ${AWS_CLI} rds describe-db-cluster-parameter-groups --db-cluster-parameter-group-name "${cluster_param_group_name}" >/dev/null 2>&1; then
                assignment_errors+=("Cluster parameter group '${cluster_param_group_name}' does not exist")
                assignment_valid="false"
            else
                echo "INFO: Cluster parameter group '${cluster_param_group_name}' validated successfully"
            fi
        fi
    fi
    
    # Validate instance parameter group if required
    if [ "${use_instance_param_group}" = "true" ]; then
        if [ -z "${instance_param_group_name}" ]; then
            assignment_errors+=("Instance parameter group name is not set for major upgrade")
            assignment_valid="false"
        else
            # Check if instance parameter group exists
            if ! ${AWS_CLI} rds describe-db-parameter-groups --db-parameter-group-name "${instance_param_group_name}" >/dev/null 2>&1; then
                assignment_errors+=("Instance parameter group '${instance_param_group_name}' does not exist")
                assignment_valid="false"
            else
                echo "INFO: Instance parameter group '${instance_param_group_name}' validated successfully"
            fi
        fi
    fi
    
    # Validate parameter group families match target engine version
    if [ "${use_cluster_param_group}" = "true" ] && [ "${assignment_valid}" = "true" ]; then
        local cluster_pg_family=$(${AWS_CLI} rds describe-db-cluster-parameter-groups --db-cluster-parameter-group-name "${cluster_param_group_name}" --query 'DBClusterParameterGroups[0].DBParameterGroupFamily' --output text)
        local expected_family="${current_engine_type}${next_engine_version_family}"
        
        if [ "${cluster_pg_family}" != "${expected_family}" ]; then
            assignment_errors+=("Cluster parameter group family '${cluster_pg_family}' does not match expected '${expected_family}'")
            assignment_valid="false"
        else
            echo "INFO: Cluster parameter group family '${cluster_pg_family}' matches target version"
        fi
    fi
    
    if [ "${use_instance_param_group}" = "true" ] && [ "${assignment_valid}" = "true" ]; then
        local instance_pg_family=$(${AWS_CLI} rds describe-db-parameter-groups --db-parameter-group-name "${instance_param_group_name}" --query 'DBParameterGroups[0].DBParameterGroupFamily' --output text)
        local expected_family="${current_engine_type}${next_engine_version_family}"
        
        if [ "${instance_pg_family}" != "${expected_family}" ]; then
            assignment_errors+=("Instance parameter group family '${instance_pg_family}' does not match expected '${expected_family}'")
            assignment_valid="false"
        else
            echo "INFO: Instance parameter group family '${instance_pg_family}' matches target version"
        fi
    fi
    
    # Report validation results
    if [ "${assignment_valid}" = "true" ]; then
        echo -e "\nINFO: Parameter group assignment validation successful"
        echo "INFO: Cluster parameter group: ${use_cluster_param_group} (${cluster_param_group_name:-N/A})"
        echo "INFO: Instance parameter group: ${use_instance_param_group} (${instance_param_group_name:-N/A})"
        
        # Export assignment decisions for use by other functions
        export USE_CLUSTER_PARAM_GROUP="${use_cluster_param_group}"
        export USE_INSTANCE_PARAM_GROUP="${use_instance_param_group}"
        
        return 0
    else
        echo -e "\nERROR: Parameter group assignment validation failed"
        for error in "${assignment_errors[@]}"; do
            echo "ERROR: ${error}"
        done
        
        if [ "${validation_only}" = "false" ]; then
            echo -e "\nERROR: Cannot proceed with upgrade due to parameter group assignment errors"
            exit 1
        fi
        
        return 1
    fi
}
##-------------------------------------------------------------------------------------



# function to upgrade Aurora cluster #
function cluster_upgrade() {
    log_aurora_operation_start "cluster_upgrade" "Upgrading Aurora cluster from ${current_engine_version} to ${next_engine_version} (${UPGRADE_SCOPE} upgrade)"
    
    # Validate cluster state before upgrade
    if ! validate_aurora_cluster_state "cluster_upgrade" "available"; then
        log_aurora_error "Aurora cluster validation failed before upgrade" "1" "cluster_upgrade" "Ensure cluster is in available state"
        exit 1
    fi
    
    local return_value=""

    # backup current Aurora cluster config #
    log_aurora_cluster_context "INFO" "Creating backup of current cluster configuration" "cluster_upgrade"
    ${AWS_CLI} rds describe-db-clusters --db-cluster-identifier ${current_cluster_id} >${LOGS_DIR}/${current_cluster_id}/cluster_current_config_backup_${current_engine_type}${current_engine_version_family}-${DATE_TIME}.txt

    # Determine parameter group assignment based on upgrade scope
    log_aurora_cluster_context "INFO" "Determining parameter group assignment for ${UPGRADE_SCOPE} upgrade" "cluster_upgrade"
    determine_parameter_group_assignment "${UPGRADE_SCOPE}" "false"
    
    # Build modify-db-cluster command parameters
    local modify_params=()
    modify_params+=("--db-cluster-identifier" "${current_cluster_id}")
    modify_params+=("--engine-version" "${next_engine_version}")
    modify_params+=("--apply-immediately")
    
    # Add cluster parameter group if required
    if [ "${USE_CLUSTER_PARAM_GROUP}" = "true" ] && [ -n "${cluster_param_group_name}" ]; then
        modify_params+=("--db-cluster-parameter-group-name" "${cluster_param_group_name}")
        log_aurora_cluster_context "INFO" "Will apply cluster parameter group: ${cluster_param_group_name}" "cluster_upgrade"
    fi
    
    # Add instance parameter group if required (major upgrades only)
    if [ "${USE_INSTANCE_PARAM_GROUP}" = "true" ] && [ -n "${instance_param_group_name}" ]; then
        modify_params+=("--db-instance-parameter-group-name" "${instance_param_group_name}")
        log_aurora_cluster_context "INFO" "Will apply instance parameter group: ${instance_param_group_name}" "cluster_upgrade"
    fi
    
    # Add major version upgrade flag if needed
    if [ "${UPGRADE_SCOPE}" = "MAJOR" ]; then
        modify_params+=("--allow-major-version-upgrade")
        log_aurora_cluster_context "INFO" "Major version upgrade flag will be applied" "cluster_upgrade"
    fi
    
    log_aurora_cluster_context "INFO" "Executing Aurora cluster upgrade command" "cluster_upgrade"
    log_aurora_cluster_context "INFO" "Command: ${AWS_CLI} rds modify-db-cluster ${modify_params[*]}" "cluster_upgrade"
    
    # Create structured log entry for upgrade start
    create_aurora_log_entry "cluster_upgrade" "started" "Aurora cluster upgrade initiated" "{\"from_version\":\"${current_engine_version}\",\"to_version\":\"${next_engine_version}\",\"upgrade_type\":\"${UPGRADE_SCOPE}\"}"
    
    # Execute the modify-db-cluster command for upgrade
    ${AWS_CLI} rds modify-db-cluster "${modify_params[@]}"
    return_value=$?
    
    log_aurora_cluster_context "INFO" "Aurora cluster upgrade command return value: ${return_value}" "cluster_upgrade"
    if [ "${return_value}" != "0" ]; then
       log_aurora_error "Aurora cluster upgrade failed during modify-db-cluster execution" "${return_value}" "cluster_upgrade" "Check AWS CLI permissions and cluster configuration"
       create_aurora_log_entry "cluster_upgrade" "failed" "Aurora cluster upgrade command failed" "{\"error_code\":\"${return_value}\"}"
       exit 1
    fi

    # wait until Aurora cluster upgrade is complete and status is available #
    log_aurora_cluster_context "INFO" "Waiting for Aurora cluster upgrade to complete" "cluster_upgrade"
    wait_till_available_cluster "upgrade"

    # check before/after upgrade version #
    log_aurora_cluster_context "INFO" "Verifying upgrade completion by checking engine version" "cluster_upgrade"
    current_cluster_engine_version_after=$( ${AWS_CLI} rds describe-db-clusters --db-cluster-identifier ${current_cluster_id} --query 'DBClusters[0].[EngineVersion]' --output text )
    log_aurora_cluster_context "INFO" "Post-upgrade engine version: ${current_cluster_engine_version_after}" "cluster_upgrade"

    # compare current engine version with next engine version #
    if [ "${current_cluster_engine_version_after}" = "${next_engine_version}" ]; then
       log_aurora_cluster_context "INFO" "Aurora cluster upgrade successful: ${current_engine_version} → ${next_engine_version}" "cluster_upgrade"
       create_aurora_log_entry "cluster_upgrade" "success" "Aurora cluster upgrade completed successfully" "{\"from_version\":\"${current_engine_version}\",\"to_version\":\"${next_engine_version}\",\"final_version\":\"${current_cluster_engine_version_after}\"}"
       log_aurora_operation_complete "cluster_upgrade" "success" "Aurora cluster upgraded from ${current_engine_version} to ${next_engine_version}"
    else
       log_aurora_error "Aurora cluster upgrade verification failed. Expected: ${next_engine_version}, Actual: ${current_cluster_engine_version_after}" "2" "cluster_upgrade" "Check Aurora cluster logs and AWS console for upgrade status"
       create_aurora_log_entry "cluster_upgrade" "failed" "Aurora cluster upgrade verification failed" "{\"expected_version\":\"${next_engine_version}\",\"actual_version\":\"${current_cluster_engine_version_after}\"}"
       exit 1
    fi

    log_aurora_cluster_context "INFO" "Aurora cluster upgrade function completed successfully" "cluster_upgrade"
}
##-------------------------------------------------------------------------------------

# function to add Aurora cluster logs to CloudWatch #
function cluster_modify_logs() {
    log_aurora_operation_start "cluster_modify_logs" "Configuring CloudWatch log exports for Aurora PostgreSQL cluster ${current_cluster_id}"
    
    local return_value=""
    local supported_log_types=()
    local failed_log_types=()
    local success_log_types=()
    
    # Get current Aurora engine version for log type compatibility checking
    local current_aurora_version=$( ${AWS_CLI} rds describe-db-clusters --db-cluster-identifier ${current_cluster_id} --query 'DBClusters[0].EngineVersion' --output text )
    log_aurora_cluster_context "INFO" "Current Aurora PostgreSQL version: ${current_aurora_version}" "cluster_modify_logs"
    
    # Define Aurora-specific log types to attempt
    # Note: Aurora PostgreSQL may not support all log types depending on version
    local log_types_to_try=("postgresql")
    
    # Check if upgrade logs might be supported (generally not available for Aurora PostgreSQL)
    # We'll attempt it but handle gracefully if it fails
    log_aurora_cluster_context "INFO" "Checking Aurora log type compatibility for version ${current_aurora_version}" "cluster_modify_logs"
    
    # First, get currently enabled log types
    local current_enabled_logs=$( ${AWS_CLI} rds describe-db-clusters --db-cluster-identifier ${current_cluster_id} --query 'DBClusters[0].EnabledCloudwatchLogsExports' --output text )
    log_aurora_cluster_context "INFO" "Currently enabled CloudWatch log exports: ${current_enabled_logs:-none}" "cluster_modify_logs"
    
    # Attempt to enable postgresql logs (primary log type for Aurora PostgreSQL)
    log_aurora_cluster_context "INFO" "Attempting to enable PostgreSQL logs for Aurora cluster" "cluster_modify_logs"
    
    ${AWS_CLI} rds modify-db-cluster \
            --db-cluster-identifier ${current_cluster_id} \
            --cloudwatch-logs-export-configuration '{"EnableLogTypes":["postgresql"]}' \
            --apply-immediately
    
    return_value="$?"
    log_aurora_cluster_context "INFO" "Aurora cluster PostgreSQL log configuration return value: ${return_value}" "cluster_modify_logs"
    
    if [ "${return_value}" = "0" ]; then
        success_log_types+=("postgresql")
        log_aurora_cluster_context "INFO" "Successfully enabled PostgreSQL logs for Aurora cluster ${current_cluster_id}" "cluster_modify_logs"
        create_aurora_log_entry "cluster_modify_logs" "success" "PostgreSQL logs enabled" "{\"log_type\":\"postgresql\",\"cluster_version\":\"${current_aurora_version}\"}"
    else
        failed_log_types+=("postgresql")
        log_aurora_cluster_context "WARNING" "Failed to enable PostgreSQL logs for Aurora cluster ${current_cluster_id}" "cluster_modify_logs"
        
        # Get detailed error information
        local error_details=$( ${AWS_CLI} rds describe-db-clusters --db-cluster-identifier ${current_cluster_id} --query 'DBClusters[0].Status' --output text )
        log_aurora_cluster_context "WARNING" "Current cluster status: ${error_details}" "cluster_modify_logs"
        create_aurora_log_entry "cluster_modify_logs" "warning" "PostgreSQL logs failed to enable" "{\"log_type\":\"postgresql\",\"error_code\":\"${return_value}\",\"cluster_status\":\"${error_details}\"}"
    fi
    
    # Attempt to enable upgrade logs (may not be supported for Aurora PostgreSQL)
    log_aurora_cluster_context "INFO" "Attempting to enable upgrade logs for Aurora cluster (may not be supported)" "cluster_modify_logs"
    
    ${AWS_CLI} rds modify-db-cluster \
            --db-cluster-identifier ${current_cluster_id} \
            --cloudwatch-logs-export-configuration '{"EnableLogTypes":["postgresql","upgrade"]}' \
            --apply-immediately 2>/dev/null
    
    local upgrade_log_return_value="$?"
    log_aurora_cluster_context "INFO" "Aurora cluster upgrade log configuration return value: ${upgrade_log_return_value}" "cluster_modify_logs"
    
    if [ "${upgrade_log_return_value}" = "0" ]; then
        success_log_types+=("upgrade")
        log_aurora_cluster_context "INFO" "Successfully enabled upgrade logs for Aurora cluster ${current_cluster_id}" "cluster_modify_logs"
        create_aurora_log_entry "cluster_modify_logs" "success" "Upgrade logs enabled" "{\"log_type\":\"upgrade\",\"cluster_version\":\"${current_aurora_version}\"}"
    else
        failed_log_types+=("upgrade")
        log_aurora_cluster_context "INFO" "Upgrade logs not supported for Aurora PostgreSQL version ${current_aurora_version} (this is expected)" "cluster_modify_logs"
        create_aurora_log_entry "cluster_modify_logs" "info" "Upgrade logs not supported" "{\"log_type\":\"upgrade\",\"cluster_version\":\"${current_aurora_version}\",\"reason\":\"not_supported_for_aurora_postgresql\"}"
    fi
    
    # Verify final log configuration
    log_aurora_cluster_context "INFO" "Verifying final CloudWatch log configuration" "cluster_modify_logs"
    local final_enabled_logs=$( ${AWS_CLI} rds describe-db-clusters --db-cluster-identifier ${current_cluster_id} --query 'DBClusters[0].EnabledCloudwatchLogsExports' --output text )
    log_aurora_cluster_context "INFO" "Final enabled CloudWatch log exports: ${final_enabled_logs:-none}" "cluster_modify_logs"
    
    # Report results
    if [ ${#success_log_types[@]} -gt 0 ]; then
        log_aurora_cluster_context "INFO" "Successfully configured CloudWatch log types for Aurora cluster ${current_cluster_id}: ${success_log_types[*]}" "cluster_modify_logs"
    fi
    
    if [ ${#failed_log_types[@]} -gt 0 ]; then
        log_aurora_cluster_context "INFO" "Log types not supported or failed for Aurora cluster ${current_cluster_id}: ${failed_log_types[*]} (may not be supported for Aurora PostgreSQL ${current_aurora_version})" "cluster_modify_logs"
    fi
    
    # Determine overall success - at least postgresql logs should be enabled
    if [[ " ${success_log_types[@]} " =~ " postgresql " ]]; then
        log_aurora_cluster_context "INFO" "Aurora cluster CloudWatch logging configuration completed successfully" "cluster_modify_logs"
        log_aurora_cluster_context "INFO" "PostgreSQL logs are now being exported to CloudWatch for cluster ${current_cluster_id}" "cluster_modify_logs"
        log_aurora_operation_complete "cluster_modify_logs" "success" "CloudWatch logging configured successfully for Aurora cluster"
        create_aurora_log_entry "cluster_modify_logs" "success" "Aurora cluster CloudWatch logging configured" "{\"enabled_logs\":\"${success_log_types[*]}\",\"failed_logs\":\"${failed_log_types[*]}\",\"final_config\":\"${final_enabled_logs}\"}"
        return 0
    else
        log_aurora_cluster_context "WARNING" "Failed to enable critical PostgreSQL logs for Aurora cluster ${current_cluster_id}" "cluster_modify_logs"
        log_aurora_cluster_context "WARNING" "This may impact monitoring and troubleshooting capabilities" "cluster_modify_logs"
        log_aurora_cluster_context "WARNING" "Please verify Aurora cluster status and CloudWatch log permissions" "cluster_modify_logs"
        log_aurora_operation_complete "cluster_modify_logs" "warning" "CloudWatch logging configuration had issues but upgrade can continue"
        create_aurora_log_entry "cluster_modify_logs" "warning" "Aurora cluster CloudWatch logging partially configured" "{\"enabled_logs\":\"${success_log_types[*]}\",\"failed_logs\":\"${failed_log_types[*]}\",\"critical_failure\":\"postgresql_logs_failed\"}"
        # Don't exit on log configuration failure as it's not critical for upgrade
        return 1
    fi
}
##-------------------------------------------------------------------------------------

# function to check pending maintenance status on Aurora cluster instances #
function cluster_pending_maint() {

    echo -e "\nINFO: Execute cluster_pending_maint function...\n"
    local return_value=""
    local maintenance_applied=false
    local failed_instances=()
    local successful_instances=()

    # Get all cluster member instances with their roles
    cluster_instances=$( ${AWS_CLI} rds describe-db-clusters --db-cluster-identifier ${current_cluster_id} --query 'DBClusters[0].DBClusterMembers[].DBInstanceIdentifier' --output text )
    writer_instance=$( ${AWS_CLI} rds describe-db-clusters --db-cluster-identifier ${current_cluster_id} --query 'DBClusters[0].DBClusterMembers[?IsClusterWriter==`true`].DBInstanceIdentifier' --output text )
    
    echo "INFO: Aurora cluster instances: ${cluster_instances}"
    echo "INFO: Writer instance: ${writer_instance}"

    if [ -z "${cluster_instances}" ]; then
        echo "ERROR: No cluster instances found for cluster ${current_cluster_id}"
        exit 1
    fi

    # Check pending maintenance for each instance in the cluster
    for instance_id in $cluster_instances; do
        echo -e "\n=========================================="
        echo "INFO: Processing maintenance for instance: ${instance_id}"
        
        # Determine instance role
        local instance_role="reader"
        if [ "${instance_id}" = "${writer_instance}" ]; then
            instance_role="writer"
        fi
        echo "INFO: Instance role: ${instance_role}"
        
        # Get instance ARN
        instance_arn=$( ${AWS_CLI} rds describe-db-instances --db-instance-identifier ${instance_id} --query 'DBInstances[0].DBInstanceArn' --output text )
        echo "INFO: Instance ARN: ${instance_arn}"

        if [ -z "${instance_arn}" ] || [ "${instance_arn}" = "None" ]; then
            echo "ERROR: Could not retrieve ARN for instance ${instance_id}"
            failed_instances+=("${instance_id}")
            continue
        fi

        # Check pending maintenance tasks with detailed output
        echo -e "\nINFO: Checking pending maintenance actions..."
        pending_maintenance_output=$( ${AWS_CLI} rds describe-pending-maintenance-actions --resource-identifier ${instance_arn} --output json 2>/dev/null )
        
        if [ $? -ne 0 ] || [ -z "${pending_maintenance_output}" ]; then
            echo "INFO: No pending maintenance actions found for ${instance_id}"
            successful_instances+=("${instance_id}")
            continue
        fi

        # Parse maintenance actions
        maintenance_actions=$( echo "${pending_maintenance_output}" | jq -r '.PendingMaintenanceActions[0].PendingMaintenanceActionDetails[]?.Action // empty' 2>/dev/null )
        
        if [ -z "${maintenance_actions}" ]; then
            echo "INFO: No pending maintenance actions for instance ${instance_id}"
            successful_instances+=("${instance_id}")
            continue
        fi

        echo "INFO: Found pending maintenance actions: ${maintenance_actions}"

        # Process each maintenance action
        for action in ${maintenance_actions}; do
            echo -e "\nINFO: Processing maintenance action: ${action}"
            
            case "${action}" in
                "system-update")
                    echo "INFO: Applying system update maintenance for ${instance_id} (${instance_role})"
                    ;;
                "db-upgrade")
                    echo "INFO: Database upgrade maintenance detected for ${instance_id} (${instance_role})"
                    echo "WARNING: DB upgrade maintenance will be handled by the upgrade process"
                    continue
                    ;;
                *)
                    echo "INFO: Processing maintenance action '${action}' for ${instance_id} (${instance_role})"
                    ;;
            esac
            
            echo -e "\nINFO: PendingMaintApply for ${instance_id} (${action}) - BEGIN - $(date)"
            
            # Apply maintenance action with error handling
            maintenance_output=$( ${AWS_CLI} rds apply-pending-maintenance-action \
                --resource-identifier ${instance_arn} \
                --apply-action ${action} \
                --opt-in-type immediate 2>&1 )
            return_value=$?
            
            echo "INFO: Maintenance command output:"
            echo "${maintenance_output}"
            
            # Handle different return scenarios
            if [ "${return_value}" = "0" ]; then
                echo "INFO: Maintenance action '${action}' applied successfully for ${instance_id}"
                maintenance_applied=true
            elif echo "${maintenance_output}" | grep -q "There is no pending.*action"; then
                echo "INFO: No pending '${action}' maintenance available for ${instance_id} - this is expected"
                return_value="0"
            elif echo "${maintenance_output}" | grep -q "already in progress"; then
                echo "INFO: Maintenance action '${action}' already in progress for ${instance_id}"
                maintenance_applied=true
                return_value="0"
            else
                echo "ERROR: Failed to apply maintenance action '${action}' for ${instance_id}"
                echo "ERROR: Return code: ${return_value}"
                failed_instances+=("${instance_id}")
                continue
            fi

            echo "INFO: PendingMaintApply for ${instance_id} (${action}) - END - $(date)"
        done

        if [[ ! " ${failed_instances[@]} " =~ " ${instance_id} " ]]; then
            successful_instances+=("${instance_id}")
        fi
    done

    # Summary of maintenance operations
    echo -e "\n=========================================="
    echo "INFO: Maintenance operation summary:"
    echo "INFO: Total instances processed: $(echo ${cluster_instances} | wc -w)"
    echo "INFO: Successful instances: ${#successful_instances[@]} (${successful_instances[*]})"
    echo "INFO: Failed instances: ${#failed_instances[@]} (${failed_instances[*]})"

    # Handle failures
    if [ ${#failed_instances[@]} -gt 0 ]; then
        echo -e "\nERROR: Maintenance failed for one or more instances"
        echo "ERROR: Failed instances: ${failed_instances[*]}"
        echo "ERROR: Please check the maintenance status manually and resolve issues before proceeding"
        exit 1
    fi

    # Wait for cluster to stabilize if maintenance was applied
    if [ "${maintenance_applied}" = "true" ]; then
        echo -e "\nINFO: Maintenance actions were applied. Waiting for Aurora cluster to stabilize..."
        wait_till_available_cluster "maintenance"
    else
        echo -e "\nINFO: No maintenance actions were required or applied."
    fi

    echo -e "\nINFO: Aurora cluster maintenance handling completed successfully\n"

}
##-------------------------------------------------------------------------------------

# function to retrieve Aurora cluster creds from secret manager #
function get_aurora_creds() {
    echo -e "\nINFO: Execute get_aurora_creds function... \n"
    
    # Call helper function to validate db_name
    check_db_name "${db_name}" || return $?

    # Get Aurora cluster information and ARN
    aurora_cluster_info=$(${AWS_CLI} rds describe-db-clusters --db-cluster-identifier ${current_cluster_id} --output json)
    cluster_arn=$(echo ${aurora_cluster_info} | jq -r '.DBClusters[0].DBClusterArn')
    
    # Get secret name from Aurora cluster tags
    tags_info=$(${AWS_CLI} rds list-tags-for-resource --resource-name ${cluster_arn} --output json)
    secret_name=$(echo ${tags_info} | jq -r --arg tag_name "${aurora_secret_tag_name}" '.TagList[] | select(.Key==$tag_name).Value')
    
    echo "aurora_secret_tag_name = ${aurora_secret_tag_name}"
    echo "secret_name = ${secret_name}"

    if [ -z "${secret_name}" ]; then
        echo -e "\nERROR: Could not find secret name in Aurora cluster tags. Please check secret and try again.\n"
        return 1
    fi

    # Get secret value
    SECRET_VALUE=$(${AWS_CLI} secretsmanager get-secret-value --secret-id ${secret_name} --query SecretString --output text)
    
    if [ -z "${SECRET_VALUE}" ]; then
        echo -e "\nERROR: Could not retrieve secret value. Please check secret and try again. \n"
        return 1
    fi
    
    # Extract username and password
    cluster_username=$(echo $SECRET_VALUE | jq -r --arg key1 "${aurora_secret_key_username}" '.[$key1]')
    cluster_password=$(echo $SECRET_VALUE | jq -r --arg key2 "${aurora_secret_key_password}" '.[$key2]')
    
    echo "cluster user name = ${cluster_username}"

    if [ -z "${cluster_username}" ] || [ "${cluster_username}" = "null" ] || [ -z "${cluster_password}" ] || [ "${cluster_password}" = "null" ]; then
        echo -e "\nERROR: Could not extract username or password from secret. Check secret and try again.\n"
        return 1
    fi

    export PGPASSWORD="${cluster_password}"
    echo "INFO: Successfully retrieved Aurora cluster credentials"
    echo ""
    
    return 0
}
##-------------------------------------------------------------------------------------
# run ANALYZE/VACUUM FREEZE commands on Aurora writer endpoint #
function run_psql_command_aurora() {

    echo -e "\nINFO: Execute run_psql_command_aurora function to run task: ${1} ...\n"

    # Call helper function to validate db_name
    check_db_name "${db_name}" || return $?

    # Create log file path
    local log_file="${LOGS_DIR}/${current_cluster_id}/${run_pre_upg_tasks}-run_aurora_db_task_${1,,}-${DATE_TIME}.log"

    # Ensure log directory exists
    mkdir -p "${LOGS_DIR}/${current_cluster_id}"

    # Initialize command status
    local cmd_status=0
    local cmd=""

    # Get Aurora cluster credentials
    get_aurora_creds || exit 1

    # Validate Aurora cluster credentials
    if [ -z "${cluster_username}" ] || [ "${cluster_username}" = "null" ] || [ -z "${cluster_password}" ] || [ "${cluster_password}" = "null" ]; then
        echo -e "\nERROR: Aurora cluster credentials NOT found. Command ${1} will NOT run. Please check and retry again. \n"
        echo "----------------------------------------------------------------"
        exit 1
    fi
    echo "INFO: Aurora cluster credentials retrieved successfully."

    {
        echo "================================================================"
        echo "Aurora PostgreSQL Command Execution Log - Started at $(date)"
        echo "================================================================"
        echo "Command Type: ${1}"
        echo "Aurora Cluster: ${current_cluster_id}"
        echo "Database Name: ${db_name}"
        echo "Writer Endpoint: ${cluster_writer_endpoint}"
        echo "Log File: ${log_file}"
        echo "----------------------------------------------------------------"

        # Test Aurora cluster writer endpoint connection
        echo "INFO: Testing Aurora cluster writer endpoint connection..."
        if ! "${PSQL_BIN}" -U "${cluster_username}" -h "${cluster_writer_endpoint}" -p "${cluster_port}" \
            -d "${db_name}" -c '\q'
        then
            echo -e "\nERROR: Failed to connect to Aurora cluster writer endpoint. Please check and retry again. \n"
            echo "----------------------------------------------------------------"
            exit 1
        fi
        echo "INFO: Aurora cluster writer endpoint connection successful"

        # Execute command based on input parameter
        case "${1}" in
            "ANALYZE")
                echo -e "\nINFO: Executing ANALYZE VERBOSE command on Aurora cluster..."
                cmd="ANALYZE VERBOSE"
                ;;
            "FREEZE")
                echo -e "\nINFO: Executing VACUUM FREEZE VERBOSE command on Aurora cluster..."
                cmd="VACUUM FREEZE VERBOSE"
                ;;
            "UNFREEZE")
                echo -e "\nINFO: Executing VACUUM VERBOSE command on Aurora cluster..."
                cmd="VACUUM VERBOSE"
                ;;
            *)
                echo "ERROR: Invalid command type: ${1}"
                echo "Valid options are: ANALYZE, FREEZE, UNFREEZE"
                echo "----------------------------------------------------------------"
                return 1
                ;;
        esac

        # Log and execute the command
        echo "Executing command: ${PSQL_BIN} -h ${cluster_writer_endpoint} -p ${cluster_port} -d ${db_name} -a -c '${cmd}'"
        echo "----------------------------------------"
        echo "Command execution started at: $(date)"
        
        # Execute PostgreSQL command on Aurora writer endpoint
        if ! "${PSQL_BIN}" -U "${cluster_username}" -h "${cluster_writer_endpoint}" -p "${cluster_port}" \
            -d "${db_name}" -a -c "\timing on" -c "${cmd}" 2>&1
        then
            cmd_status=$?
            echo "Command failed with status: ${cmd_status}"
        fi

        echo "Command execution completed at: $(date)"
        echo "----------------------------------------"

        # Check command execution status
        if [ "${cmd_status}" -eq 0 ]; then
            echo "SUCCESS: ${1} command completed successfully on Aurora cluster"
        else
            echo "ERROR: ${1} command failed with exit status ${cmd_status} on Aurora cluster"
        fi

        echo "----------------------------------------------------------------"
        echo "Operation completed at: $(date)"
        echo "================================================================"
        echo ""

    } 2>&1 | tee "${log_file}"

    return ${cmd_status}
}
##-------------------------------------------------------------------------------------

# drop REPLICATION SLOT in Aurora cluster if exists (applies to MAJOR VERSION UPGRADE only) #
function run_psql_drop_repl_slot() {

    echo -e "\nINFO: Execute run_psql_drop_repl_slot function...\n"

    # Call helper function to validate db_name
    check_db_name "${db_name}" || return $?

    # Create log file path
    local log_file="${LOGS_DIR}/${current_cluster_id}/${run_pre_upg_tasks}-aurora_replication_slot_${DATE_TIME}.log"
    local exit_status=0

    # Ensure log directory exists
    mkdir -p "${LOGS_DIR}/${current_cluster_id}"

    # Get Aurora cluster credentials from secret manager
    get_aurora_creds || exit 1

    # Validate Aurora cluster credentials
    if [ -z "${cluster_username}" ] || [ "${cluster_username}" = "null" ] || [ -z "${cluster_password}" ] || [ "${cluster_password}" = "null" ]; then
        echo "ERROR: Aurora cluster credentials NOT found."
        echo "ERROR: [REPLICATION SLOTS] Please check if the Aurora cluster has REPLICATION SLOTS. MAJOR VERSION UPGRADE will fail if there are one or more REPLICATION SLOTS."
        echo "ERROR: [Extension check] Please check if there are extensions on older version which may not be compatible with target version. MAJOR VERSION will fail if there are extensions that are not compatible with target version."

        echo "----------------------------------------------------------------"
        exit 1
    fi
    echo "INFO: Aurora cluster credentials retrieved successfully."

    {
        echo "================================================================"
        echo "Aurora Replication Slot Operation Log - Started at $(date)"
        echo "================================================================"
        echo "Aurora Cluster: ${current_cluster_id}"
        echo "Writer Endpoint: ${cluster_writer_endpoint}"
        echo "Log File: ${log_file}"
        echo "----------------------------------------------------------------"

        # Check for existing replication slots on Aurora writer endpoint
        echo "INFO: Checking for existing replication slots on Aurora cluster..."
        repl_slot_count=$(${PSQL_BIN} -U "${cluster_username}" -h "${cluster_writer_endpoint}" -d "${db_name}" -AXqtc "SELECT COUNT(*) cnt FROM pg_replication_slots" 2>&1)
        
        if [ $? -ne 0 ]; then
            echo -e "\nERROR: Failed to query replication slots on Aurora cluster. Please check and retry again. \n"
            echo "${repl_slot_count}"
            exit 1
        fi

        echo "INFO: Current replication slot count on Aurora cluster = ${repl_slot_count}"

        # Process replication slots if they exist
        if [ "${repl_slot_count}" -gt 0 ]; then

            echo "INFO: Found ${repl_slot_count} replication slot(s) on Aurora cluster."
            
            # Log current replication slots
            echo "INFO: Capturing current replication slot details on Aurora cluster..."
            echo "Current replication slots:"
            echo "----------------------------------------"
            ${PSQL_BIN} -U "${cluster_username}" -h "${cluster_writer_endpoint}" -d "${db_name}" \
                -c "SELECT slot_name, plugin, slot_type, database, active, xmin FROM pg_replication_slots"
            echo "----------------------------------------"

            if [ "${cluster_drop_replication_slot}" = "Y" ]; then 

                # Drop replication slots on Aurora cluster
                echo "INFO: Dropping replication slots on Aurora cluster..."
                drop_result=$(${PSQL_BIN} -U "${cluster_username}" -h "${cluster_writer_endpoint}" -d "${db_name}" \
                    -c "SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name IN (SELECT slot_name FROM pg_replication_slots)" 2>&1)
                
                if [ $? -ne 0 ]; then
                    echo -e "\nERROR: Failed to drop replication slots on Aurora cluster. Please check and retry again. \n"
                    echo "${drop_result}"
                    exit 1
                fi

                echo "INFO: Aurora cluster replication slot operation result: ${drop_result}"
                echo "----------------------------------------"

                # Verify slots were dropped
                echo "INFO: Verifying replication slots after drop operation on Aurora cluster..."
                echo "Remaining replication slots:"
                echo "----------------------------------------"
                ${PSQL_BIN} -U "${cluster_username}" -h "${cluster_writer_endpoint}" -d "${db_name}" \
                    -c "SELECT slot_name, plugin, slot_type, database, active, xmin FROM pg_replication_slots"
                echo "----------------------------------------"

                # Final count verification
                final_count=$(${PSQL_BIN} -U "${cluster_username}" -h "${cluster_writer_endpoint}" -d "${db_name}" -AXqtc "SELECT COUNT(*) cnt FROM pg_replication_slots")
                
                if [ $? -ne 0 ]; then
                    echo -e "\nERROR: Failed to get final replication slot count on Aurora cluster. Please check and retry again. \n"
                    exit 1
                fi

                echo "INFO: Final replication slot count on Aurora cluster = ${final_count}"

                if [ "${final_count}" -eq 0 ]; then
                    echo "SUCCESS: All replication slots were successfully dropped from Aurora cluster."
                else
                    echo -e "\nERROR: ${final_count} replication slots still exist on Aurora cluster. Upgrade cannot proceed until they are dropped. Please check and retry again. \n"
                    exit 1
                fi

            else
                echo "IMPORTANT: ${repl_slot_count} replication slot(s) found on Aurora cluster. All replication slots MUST be dropped before proceeding with major version upgrade."
                echo "INFO: To manually drop replication slot(s), use this command in each database prior to MAJOR version upgrade:"
                echo "INFO  SELECT pg_drop_replication_slot(slot_name) FROM pg_replication_slots WHERE slot_name IN (SELECT slot_name FROM pg_replication_slots);"
                echo "INFO: Other option is to set this variable \"cluster_drop_replication_slot\" to \"Y\" prior to running the MAJOR version UPGRADE; using this option,"
                echo "INFO: the script will drop replication slot(s) as part of the MAJOR version UPGRADE process."
            fi

        else
            echo "INFO: No replication slots found on Aurora cluster. No action needed."

        fi

        echo "----------------------------------------------------------------"
        echo "Operation completed at: $(date)"
        echo "================================================================"
        echo ""

    } 2>&1 | tee "${log_file}"

    return 0
}
##-------------------------------------------------------------------------------------

# copy upgrade files to s3 bucket for future reference #
function copy_logs_to_s3() {

    if [ -n "${S3_BUCKET_PATCH_LOGS}" ]; then

	   echo -e "\nINFO: Execute copy_logs_to_s3 function...\n"

	   echo -e "\nINFO: Copy Aurora cluster log files to S3"
	   ${AWS_CLI} s3 sync "${LOGS_DIR}/" "s3://${S3_BUCKET_PATCH_LOGS}/"
	   echo ""

	   # S3 logs directory #
	   S3_LOGS_DIR="s3://${S3_BUCKET_PATCH_LOGS}/${current_cluster_id}/"
	   echo -e "\nS3_LOGS_DIR = ${S3_LOGS_DIR} \n"

    fi

}
##-------------------------------------------------------------------------------------

# function to take Aurora cluster snapshot/backup if required #
function cluster_snapshot() {

    echo -e "\nINFO: Execute cluster_snapshot function...\n"
    local return_value=""
    local snapshot_status=""
    local max_wait_minutes=60
    local wait_interval=30
    local elapsed_seconds=0
    local max_wait_seconds=$((max_wait_minutes * 60))

    # NEW LOGIC: Validate cluster snapshot requirements based on upgrade type AND phase
    if [ "${UPGRADE_SCOPE}" = "MAJOR" ]; then
        if [ "${run_pre_upg_tasks}" = "PREUPGRADE" ]; then
            echo -e "\nINFO: MAJOR VERSION UPGRADE detected - PREUPGRADE phase"
            echo "INFO: Manual SNAPSHOT creation IS required for MAJOR UPGRADES during PREUPGRADE"
            echo "INFO: Creating manual pre-upgrade SNAPSHOT for MAJOR UPGRADE - $(date)"
            log_aurora_cluster_context "INFO" "Creating manual snapshot for major upgrade during PREUPGRADE phase" "cluster_snapshot" "MajorUpgrade"
        else
            echo -e "\nINFO: MAJOR VERSION UPGRADE detected - UPGRADE phase"
            echo "INFO: Manual SNAPSHOT creation is NOT required for MAJOR UPGRADES during UPGRADE"
            echo "INFO: Aurora will automatically create a SNAPSHOT during MAJOR UPGRADE - $(date)"
            log_aurora_cluster_context "INFO" "Skipping manual snapshot for major upgrade during UPGRADE phase (Aurora automatic snapshot will be created)" "cluster_snapshot" "MajorUpgrade"
            return 0
        fi
    fi
    
    # For minor upgrades, check if manual snapshot is required (both PREUPGRADE and UPGRADE phases)
    if [ "${UPGRADE_SCOPE}" = "MINOR" ]; then
        echo -e "\nINFO: MINOR VERSION UPGRADE detected - ${run_pre_upg_tasks} phase"
        echo "INFO: Manual SNAPSHOT creation IS required for MINOR UPGRADES during ${run_pre_upg_tasks}"
        if [ "${cluster_snapshot_required}" = "N" ]; then
            echo "INFO: Manual Aurora Cluster SNAPSHOT disabled by configuration - $(date)"
            log_aurora_cluster_context "INFO" "Manual snapshot disabled for minor upgrade by cluster_snapshot_required=N" "cluster_snapshot" "MinorUpgrade"
            return 0
        fi
        echo "INFO: Creating manual SNAPSHOT for MINOR UPGRADE during ${run_pre_upg_tasks} - $(date)"
        log_aurora_cluster_context "INFO" "Creating manual snapshot for minor upgrade during ${run_pre_upg_tasks} phase" "cluster_snapshot" "MinorUpgrade"
    fi

    if [ "${cluster_snapshot_required}" = "Y" ]; then

        # Generate snapshot name with proper naming conventions
        cluster_snapshot_name="${current_cluster_id}-backup-pre-${UPGRADE_SCOPE}-upgrade-${next_engine_version}-${DATE_TIME}"
        # Replace dots with dashes for valid snapshot identifier
        cluster_snapshot_name=$( echo "${cluster_snapshot_name//./-}" )
        
        # Validate snapshot name length (max 255 characters)
        if [ ${#cluster_snapshot_name} -gt 255 ]; then
            echo "ERROR: Snapshot name too long (${#cluster_snapshot_name} characters, max 255)"
            exit 1
        fi

        echo ""
        echo "INFO: Creating Aurora Cluster SNAPSHOT [ ${cluster_snapshot_name} ] - $(date)"
        echo "INFO: SNAPSHOT type: Manual pre-upgrade backup"
        echo "INFO: Upgrade scope: ${UPGRADE_SCOPE}"

        # Check if snapshot already exists
        if ${AWS_CLI} rds describe-db-cluster-snapshots --db-cluster-snapshot-identifier "${cluster_snapshot_name}" >/dev/null 2>&1; then
            echo "WARNING: SNAPSHOT with name '${cluster_snapshot_name}' already exists"
            echo "INFO: Using existing SNAPSHOT for pre-upgrade backup"
            return 0
        fi

        # Create the cluster snapshot
        ${AWS_CLI} rds create-db-cluster-snapshot \
            --db-cluster-identifier ${current_cluster_id} \
            --db-cluster-snapshot-identifier ${cluster_snapshot_name} \
            --tags '[{"Key": "Purpose","Value": "Pre-upgrade backup"},{"Key": "UpgradeScope","Value": "'"${UPGRADE_SCOPE}"'"},{"Key": "TargetVersion","Value": "'"${next_engine_version}"'"},{"Key": "CreatedBy","Value": "aurora-psql-patch-script"}]'
        
        return_value=$?
        echo "CreateClusterSnapshot ReturnValue = ${return_value}"

        if [ "${return_value}" != "0" ]; then
          echo -e "\nERROR: Aurora Cluster SNAPSHOT creation failed (return code: ${return_value})\n"
          exit 1
        fi

        echo -e "\nINFO: Monitoring SNAPSHOT creation progress..."
        
        # Monitor snapshot creation progress
        while [ ${elapsed_seconds} -lt ${max_wait_seconds} ]; do
            snapshot_status=$(${AWS_CLI} rds describe-db-cluster-snapshots \
                --db-cluster-snapshot-identifier "${cluster_snapshot_name}" \
                --query 'DBClusterSnapshots[0].Status' \
                --output text 2>/dev/null | tr '[:lower:]' '[:upper:]')
            
            case "${snapshot_status}" in
                "AVAILABLE")
                    echo -e "\nINFO: Aurora cluster SNAPSHOT created successfully"
                    echo "INFO: SNAPSHOT ID: ${cluster_snapshot_name}"
                    echo "INFO: SNAPSHOT status: ${snapshot_status}"
                    echo "INFO: Total SNAPSHOT time: $((elapsed_seconds / 60)) minutes"
                    break
                    ;;
                "CREATING")
                    echo "INFO: SNAPSHOT-Creation [${elapsed_seconds}s/${max_wait_seconds}s] Status: ${snapshot_status} - $(date)"
                    ;;
                "FAILED"|"DELETED")
                    echo -e "\nERROR: Aurora cluster SNAPSHOT creation failed"
                    echo "ERROR: SNAPSHOT status: ${snapshot_status}"
                    exit 1
                    ;;
                *)
                    echo "INFO: SNAPSHOT-Creation [${elapsed_seconds}s/${max_wait_seconds}s] Status: ${snapshot_status} - $(date)"
                    ;;
            esac
            
            if [ "${snapshot_status}" = "AVAILABLE" ]; then
                break
            fi
            
            sleep ${wait_interval}s
            elapsed_seconds=$((elapsed_seconds + wait_interval))
        done
        
        # Check if timeout was reached
        if [ ${elapsed_seconds} -ge ${max_wait_seconds} ] && [ "${snapshot_status}" != "AVAILABLE" ]; then
            echo -e "\nERROR: Timeout waiting for snapshot creation to complete"
            echo "ERROR: Current snapshot status: ${snapshot_status}"
            echo "ERROR: Maximum wait time of ${max_wait_minutes} minutes exceeded"
            exit 1
        fi

        # wait until Aurora cluster status is available after snapshot #
        echo -e "\nINFO: Waiting for Aurora cluster to return to available state...\n"
      	wait_till_available_cluster "snapshot"

    else

      echo ""
      echo "INFO: Manual Aurora Cluster Snapshot NOT required - $(date)"
      if [ "${UPGRADE_SCOPE}" = "MAJOR" ]; then
          echo "INFO: Aurora will automatically create a snapshot before major upgrade"
      fi

    fi

}
##-------------------------------------------------------------------------------------

# function to create Aurora cluster clone (copy-on-write) before upgrade operations #
function cluster_clone() {
    echo -e "\nINFO: Execute cluster_clone function...\n"
    
    local return_value=""
    local clone_status=""
    local max_wait_minutes=60
    local wait_interval=30
    local elapsed_seconds=0
    local max_wait_seconds=$((max_wait_minutes * 60))
    local clone_cluster_id="${current_cluster_id}-clone-${DATE_TIME}"
    
    # Check if cluster clone is required
    if [ "${cluster_clone_required}" = "N" ]; then
        echo "INFO: Aurora Cluster CLONE disabled by configuration - $(date)"
        log_aurora_cluster_context "INFO" "Cluster clone disabled by cluster_clone_required=N" "cluster_clone" "CloneSkipped"
        return 0
    fi
    
    # Only create clone for UPGRADE phase (not PREUPGRADE)
    if [ "${run_pre_upg_tasks}" = "PREUPGRADE" ]; then
        echo "INFO: Aurora Cluster CLONE not required for PREUPGRADE phase - $(date)"
        log_aurora_cluster_context "INFO" "Cluster clone skipped for PREUPGRADE phase" "cluster_clone" "CloneSkipped"
        return 0
    fi
    
    echo "INFO: Creating Aurora Cluster CLONE for ${UPGRADE_SCOPE} upgrade - $(date)"
    echo "INFO: Source Cluster: ${current_cluster_id}"
    echo "INFO: Clone Cluster: ${clone_cluster_id}"
    echo "INFO: Clone Type: copy-on-write (fast, space-efficient)"
    
    log_aurora_cluster_context "INFO" "Creating copy-on-write clone before ${UPGRADE_SCOPE} upgrade" "cluster_clone" "CloneCreation"
    
    # Check if clone already exists
    if ${AWS_CLI} rds describe-db-clusters --db-cluster-identifier "${clone_cluster_id}" >/dev/null 2>&1; then
        echo "WARNING: CLONE with identifier '${clone_cluster_id}' already exists"
        echo "INFO: Using existing CLONE for pre-upgrade backup"
        log_aurora_cluster_context "WARNING" "Clone cluster already exists: ${clone_cluster_id}" "cluster_clone" "CloneExists"
        return 0
    fi
    
    # Create copy-on-write clone
    echo -e "\nINFO: Creating Aurora cluster copy-on-write clone..."
    echo "INFO: AWS CLI Command: aws rds restore-db-cluster-to-point-in-time \\"
    echo "INFO:   --source-db-cluster-identifier ${current_cluster_id} \\"
    echo "INFO:   --db-cluster-identifier ${clone_cluster_id} \\"
    echo "INFO:   --restore-type copy-on-write \\"
    echo "INFO:   --use-latest-restorable-time"
    
    ${AWS_CLI} rds restore-db-cluster-to-point-in-time \
        --source-db-cluster-identifier "${current_cluster_id}" \
        --db-cluster-identifier "${clone_cluster_id}" \
        --restore-type copy-on-write \
        --use-latest-restorable-time
    
    return_value=$?
    
    if [ "${return_value}" != "0" ]; then
        echo -e "\nERROR: Aurora cluster CLONE creation failed"
        log_aurora_error "Aurora cluster clone creation failed" "${return_value}" "cluster_clone" "Check Aurora cluster permissions and source cluster status" "clone_creation_failed"
        exit 1
    fi
    
    echo -e "\nINFO: Aurora cluster CLONE creation initiated successfully"
    echo "INFO: Clone Identifier: ${clone_cluster_id}"
    echo "INFO: Monitoring CLONE creation progress..."
    
    log_aurora_cluster_context "INFO" "Clone creation initiated successfully" "cluster_clone" "CloneCreation"
    
    # Monitor clone creation progress
    while [ ${elapsed_seconds} -lt ${max_wait_seconds} ]; do
        clone_status=$(${AWS_CLI} rds describe-db-clusters \
            --db-cluster-identifier "${clone_cluster_id}" \
            --query 'DBClusters[0].Status' \
            --output text 2>/dev/null | tr '[:lower:]' '[:upper:]')
        
        case "${clone_status}" in
            "AVAILABLE")
                echo -e "\nINFO: Aurora cluster CLONE created successfully"
                echo "INFO: CLONE ID: ${clone_cluster_id}"
                echo "INFO: CLONE status: ${clone_status}"
                echo "INFO: Total CLONE time: $((elapsed_seconds / 60)) minutes"
                log_aurora_cluster_context "INFO" "Clone creation completed successfully" "cluster_clone" "CloneComplete"
                
                # Store clone information for potential rollback
                echo "CLONE_CLUSTER_ID=${clone_cluster_id}" >> "${LOGS_DIR}/${current_cluster_id}/clone-info.txt"
                echo "CLONE_STATUS=${clone_status}" >> "${LOGS_DIR}/${current_cluster_id}/clone-info.txt"
                echo "CLONE_CREATION_TIME=$(date)" >> "${LOGS_DIR}/${current_cluster_id}/clone-info.txt"
                
                break
                ;;
            "CREATING")
                echo "INFO: CLONE-Creation [${elapsed_seconds}s/${max_wait_seconds}s] Status: ${clone_status} - $(date)"
                ;;
            "FAILED"|"DELETED")
                echo -e "\nERROR: Aurora cluster CLONE creation failed"
                echo "ERROR: CLONE status: ${clone_status}"
                log_aurora_error "Aurora cluster clone creation failed with status: ${clone_status}" "1" "cluster_clone" "Check Aurora cluster logs and retry clone creation" "clone_creation_failed"
                exit 1
                ;;
            *)
                echo "INFO: CLONE-Creation [${elapsed_seconds}s/${max_wait_seconds}s] Status: ${clone_status} - $(date)"
                ;;
        esac
        
        sleep ${wait_interval}s
        elapsed_seconds=$((elapsed_seconds + wait_interval))
    done
    
    # Check if clone creation timed out
    if [ ${elapsed_seconds} -ge ${max_wait_seconds} ] && [ "${clone_status}" != "AVAILABLE" ]; then
        echo -e "\nERROR: Aurora cluster CLONE creation timed out"
        echo "ERROR: Maximum wait time of ${max_wait_minutes} minutes exceeded"
        echo "ERROR: Current CLONE status: ${clone_status}"
        log_aurora_error "Aurora cluster clone creation timed out after ${max_wait_minutes} minutes" "1" "cluster_clone" "Check Aurora cluster status manually and retry if needed" "clone_creation_timeout"
        exit 1
    fi
    
    echo -e "\nINFO: Aurora cluster CLONE creation completed successfully"
    echo "INFO: Clone can be used for rollback if upgrade fails"
    echo "INFO: Remember to delete clone after successful upgrade to avoid costs"
    
    # Send notification if configured
    #if [ -n "${SNS_TOPIC_ARN_EMAIL}" ]; then
    #    send_email "Aurora Clone Created" "Aurora cluster clone '${clone_cluster_id}' created successfully for upgrade safety"
    #fi
    
    return 0
}
##-------------------------------------------------------------------------------------

# function to send email #
function send_email() {
    local status="${1:-COMPLETED}"
    local details="${2:-}"
    
    if [ -n "${SNS_TOPIC_ARN_EMAIL}" ]; then
        echo -e "\nINFO: Execute send_email function with status: ${status}...\n"
        
        # Build notification message
        local notification_message="Status: ${status}"
        
        # Add details if provided
        if [ -n "${details}" ]; then
            notification_message="${notification_message}
Details: ${details}"
        fi
        
        # Add upgrade information if available
        if [ -n "${current_engine_version}" ] && [ -n "${next_engine_version}" ]; then
            notification_message="${notification_message}
Upgrade: ${current_engine_version} → ${next_engine_version}"
        fi
        
        # Add upgrade scope if available
        if [ -n "${UPGRADE_SCOPE}" ]; then
            notification_message="${notification_message}
Upgrade Type: ${UPGRADE_SCOPE}"
        fi
        
        # Add log location
        if [ -n "${S3_LOGS_DIR}" ]; then
            notification_message="${notification_message}
Logs: ${S3_LOGS_DIR}"
        fi
        
        # Send SNS notification
        ${AWS_CLI} sns publish \
            --topic-arn ${SNS_TOPIC_ARN_EMAIL} \
            --message "${notification_message}" \
            --subject "${EMAIL_SUBJECT} [${current_cluster_id}] - ${status}"
        
        local sns_return_code=$?
        if [ "${sns_return_code}" -eq 0 ]; then
            echo "INFO: SNS notification sent successfully with status: ${status}"
        else
            echo "WARNING: Failed to send SNS notification (return code: ${sns_return_code})"
        fi
    else
        echo "INFO: SNS_TOPIC_ARN_EMAIL not configured - skipping email notification"
    fi
}
##-------------------------------------------------------------------------------------

# function to check if the next-engine-version is valid for the current aurora-postgresql cluster version #
check_aurora_upgrade_version() {
    local cluster_id="$1"
    local target_version="$2"
    
    echo -e "\nINFO: Execute check_aurora_upgrade_version function...\n"
    echo "INFO: Validating Aurora PostgreSQL upgrade path compatibility..."
    echo "INFO: Aurora Cluster:     ${cluster_id}"
    echo "INFO: Current Version:    ${current_engine_version}"
    echo "INFO: Requested Version:  ${target_version}"
    echo "INFO: Engine Type:        ${current_engine_type}"
    
    # Validate engine type is aurora-postgresql
    if [ "${current_engine_type}" != "aurora-postgresql" ]; then
        echo -e "\nERROR: This script is designed for Aurora PostgreSQL clusters only."
        echo "ERROR: Current engine type: ${current_engine_type}"
        echo "ERROR: Expected engine type: aurora-postgresql"
        exit 1
    fi
    
    # Validate target version format
    if ! echo "${target_version}" | grep -qE '^[0-9]+\.[0-9]+(\.[0-9]+)?$'; then
        echo -e "\nERROR: Invalid target version format: ${target_version}"
        echo "ERROR: Expected format: X.Y or X.Y.Z (e.g., 15.4, 14.9)"
        exit 1
    fi
    
    # Get current Aurora cluster information for compatibility checks
    echo -e "\nINFO: Retrieving Aurora engine version information..."
    
    # Get valid upgrade targets with IsMajorVersionUpgrade flag for aurora-postgresql
    valid_versions_output=$(${AWS_CLI} rds describe-db-engine-versions \
        --engine aurora-postgresql \
        --engine-version "${current_engine_version}" \
        --query 'DBEngineVersions[].ValidUpgradeTarget[].[EngineVersion,IsMajorVersionUpgrade,Description]' \
        --output text 2>/dev/null)
    
    local return_value=$?
    if [ "${return_value}" != "0" ] || [ -z "${valid_versions_output}" ]; then
        echo -e "\nERROR: Failed to retrieve valid Aurora upgrade versions for ${current_engine_version}"
        echo "ERROR: Please verify the current engine version and AWS CLI configuration"
        exit 1
    fi
    
    # Extract just version and major upgrade flag for processing
    valid_versions=$(echo "${valid_versions_output}" | awk '{print $1 " " $2}')
    
    echo -e "\nINFO: Performing Aurora-specific upgrade compatibility checks..."
    
    # Check if target version is in the list of valid upgrades
    if echo "${valid_versions}" | awk '{print $1}' | grep -q "^${target_version}$"; then
        # Get upgrade type (major/minor) and set global variable
        is_major=$(echo "${valid_versions}" | grep "^${target_version}" | awk '{print $2}')
        
        if [ "${is_major}" = "True" ]; then
            UPGRADE_SCOPE="MAJOR"
            upgrade_type="MAJOR"
            echo -e "\nINFO: Aurora PostgreSQL MAJOR version upgrade detected"
            echo "INFO: Major upgrade requirements:"
            echo "INFO:   - Both cluster and instance parameter groups will be created"
            echo "INFO:   - Automatic cluster snapshot will be taken by Aurora"
            echo "INFO:   - Replication slots should be checked and potentially dropped"
            echo "INFO:   - Extension compatibility will be validated post-upgrade"
        else
            UPGRADE_SCOPE="MINOR"
            upgrade_type="MINOR"
            echo -e "\nINFO: Aurora PostgreSQL MINOR version upgrade detected"
            echo "INFO: Minor upgrade requirements:"
            echo "INFO:   - Only cluster parameter group will be used"
            echo "INFO:   - No automatic snapshot required (but can be taken manually)"
            echo "INFO:   - Replication slots can remain active"
        fi
        
        # Additional Aurora-specific compatibility checks
        echo -e "\nINFO: Performing additional Aurora compatibility checks..."
        
        # Check for Aurora-specific version constraints
        current_major=$(echo "${current_engine_version}" | cut -d. -f1)
        target_major=$(echo "${target_version}" | cut -d. -f1)
        
        # Validate upgrade path constraints
        if [ "${upgrade_type}" = "major" ]; then
            # Check for supported major upgrade paths
            case "${current_major}" in
                "11")
                    if [ "${target_major}" != "12" ] && [ "${target_major}" != "13" ] && [ "${target_major}" != "14" ] && [ "${target_major}" != "15" ]; then
                        echo -e "\nWARNING: Unusual major upgrade path from PostgreSQL ${current_major} to ${target_major}"
                        echo "WARNING: Please verify this upgrade path is supported in your Aurora region"
                    fi
                    ;;
                "12")
                    if [ "${target_major}" != "13" ] && [ "${target_major}" != "14" ] && [ "${target_major}" != "15" ]; then
                        echo -e "\nWARNING: Unusual major upgrade path from PostgreSQL ${current_major} to ${target_major}"
                        echo "WARNING: Please verify this upgrade path is supported in your Aurora region"
                    fi
                    ;;
                "13")
                    if [ "${target_major}" != "14" ] && [ "${target_major}" != "15" ]; then
                        echo -e "\nWARNING: Unusual major upgrade path from PostgreSQL ${current_major} to ${target_major}"
                        echo "WARNING: Please verify this upgrade path is supported in your Aurora region"
                    fi
                    ;;
                "14")
                    if [ "${target_major}" != "15" ]; then
                        echo -e "\nWARNING: Unusual major upgrade path from PostgreSQL ${current_major} to ${target_major}"
                        echo "WARNING: Please verify this upgrade path is supported in your Aurora region"
                    fi
                    ;;
            esac
        fi
        
        # Export upgrade scope for use by other functions
        export UPGRADE_SCOPE
        
        echo -e "\nINFO: Aurora upgrade path validation successful"
        echo "INFO: Version ${target_version} is a valid ${upgrade_type} version upgrade target"
        echo "INFO: Upgrade scope set to: ${UPGRADE_SCOPE}"
        
        return 0
    else
        echo -e "\nERROR: Version ${target_version} is not a valid upgrade target for Aurora PostgreSQL ${current_engine_version}"
        echo -e "\nINFO: Available Aurora PostgreSQL upgrade options:"
        echo "INFO: ================================================================"
        printf "INFO: %-15s %-15s %-40s\n" "VERSION" "UPGRADE TYPE" "DESCRIPTION"
        echo "INFO: ================================================================"
        
        # Format and display available versions with descriptions
        echo "${valid_versions_output}" | while IFS=$'\t' read -r version is_major description; do
            upgrade_type=$([ "${is_major}" = "True" ] && echo "major" || echo "minor")
            # Truncate description if too long
            short_desc=$(echo "${description}" | cut -c1-35)
            if [ ${#description} -gt 35 ]; then
                short_desc="${short_desc}..."
            fi
            printf "INFO: %-15s %-15s %-40s\n" "${version}" "${upgrade_type}" "${short_desc}"
        done
        echo "INFO: ================================================================"
        
        echo -e "\nINFO: Please select a valid upgrade version from the list above."
        return 1
    fi
}
##-------------------------------------------------------------------------------------

# function to determine if upgrade/patching path is MINOR or MAJOR #
function check_aurora_upgrade_type() {

    echo -e "\nChecking Aurora upgrade type..."

    # Extract major version numbers (family)
    current_engine_version_family=$(echo "$current_engine_version" | cut -d. -f1)
    next_engine_version_family=$(echo "$next_engine_version" | cut -d. -f1)

    echo "Current Aurora version: $current_engine_version (family: $current_engine_version_family)"
    echo "Target Aurora version: $next_engine_version (family: $next_engine_version_family)"

    # Compare versions directly without version_to_number function
    if [ "$next_engine_version_family" -gt "$current_engine_version_family" ]; then
        UPGRADE_SCOPE="MAJOR"
        echo -e "\nINFO: Aurora major version upgrade required (family $current_engine_version_family -> $next_engine_version_family)"
        return 0
    fi

    # Compare full versions for minor upgrade check
    current_engine_version_1=$(echo "$current_engine_version" | tr -d '.')
    next_engine_version_1=$(echo "$next_engine_version" | tr -d '.')

    if [ "$current_engine_version_1" -eq "$next_engine_version_1" ]; then
        echo -e "\nINFO: Current and target Aurora versions are identical. No upgrade required."
        exit 0
    elif [ "$current_engine_version_1" -gt "$next_engine_version_1" ]; then
        echo -e "\nINFO: Current Aurora version is newer than target. No upgrade required."
        exit 0
    else
        UPGRADE_SCOPE="MINOR"
        echo -e "\nINFO: Aurora minor version upgrade required"
        echo "INFO: Aurora Cluster Parameter Group remains unchanged"
        cluster_param_group_name=${current_cluster_param_group}
        return 0
    fi
}
##-------------------------------------------------------------------------------------

# function to update PostgreSQL extensions on Aurora cluster
function update_extensions() {

    echo -e "\nINFO: Execute update_extensions function...\n"

    # Call helper function to validate db_name
    check_db_name "${db_name}" || return $?

    # Create log file path
    local log_file="${LOGS_DIR}/${current_cluster_id}/${run_pre_upg_tasks}-update_aurora_db_extensions_${DATE_TIME}.log"

    # Ensure log directory exists
    mkdir -p "${LOGS_DIR}/${current_cluster_id}"

    # get Aurora cluster creds from secret manager #
    get_aurora_creds || exit 1

    # Check if Aurora cluster credentials exist
    if [ -z "${cluster_username}" ] || [ "${cluster_username}" = "null" ] || [ -z "${cluster_password}" ] || [ "${cluster_password}" = "null" ]; then
        echo -e "\nERROR: Aurora cluster credentials not found in secret manager. Please check and retry again. \n"
        exit 1
    fi

    # Start logging
    {
        echo "================================================================"
        echo "Execute update Aurora DB extensions Log - Started at $(date)"
        echo "================================================================"
        echo "Aurora Cluster: ${current_cluster_id}"
        echo "Writer Endpoint: ${cluster_writer_endpoint}"
        echo "Log File: ${log_file}"
        echo "----------------------------------------------------------------"

        echo -e "\nINFO: Execute update_extensions function on Aurora cluster..."
        echo -e "INFO: Started at $(date)"

        # Connect to the Aurora PostgreSQL cluster writer endpoint
        echo "INFO: Testing Aurora cluster writer endpoint connection..."
        if ! ${PSQL_BIN} -U "${cluster_username}" -h "${cluster_writer_endpoint}" -p "${cluster_port}" -d "${db_name}" -c '\q' >/dev/null 2>&1; then
            echo -e "\nERROR: Failed to connect to the Aurora PostgreSQL cluster writer endpoint. Please check and retry again. \n"
            exit 1
        fi
        echo "INFO: Aurora cluster writer endpoint connection successful"

        # Update extensions using a PL/pgSQL anonymous code block
        echo -e "\nINFO: Starting extension updates on Aurora cluster..."
        ${PSQL_BIN} -U "${cluster_username}" -h "${cluster_writer_endpoint}" -p "${cluster_port}" -d "${db_name}" <<EOF
            \timing on
            
            SELECT current_timestamp AS "Start Time";

            DO \$\$
            DECLARE
                rec RECORD;
                newest_version TEXT;
                extensions_updated BOOLEAN := FALSE;
            BEGIN
                FOR rec IN
                    SELECT extname, extversion, (
                        SELECT version newest_version
                        FROM pg_available_extension_versions
                        WHERE name = extname
                        ORDER BY newest_version DESC
                        LIMIT 1
                    ) AS newest_version
                    FROM pg_extension
                LOOP
                    IF rec.newest_version IS NOT NULL THEN
                        EXECUTE 'ALTER EXTENSION ' || quote_ident(rec.extname) || ' UPDATE TO ' || quote_literal(rec.newest_version);
                        RAISE NOTICE 'Updated extension % to version %', rec.extname, rec.newest_version;
                        extensions_updated := TRUE;
                    END IF;
                END LOOP;

                IF NOT extensions_updated THEN
                    RAISE NOTICE 'No extensions were updated on Aurora cluster.';
                END IF;
            END\$\$;

            SELECT current_timestamp AS "End Time";
EOF

        if [ $? -ne 0 ]; then
            echo -e "\nERROR: Failed to update extensions on Aurora cluster. Please check and retry again. \n"
            exit 1
        fi

        echo -e "\nINFO: Extension update process completed on Aurora cluster at $(date)"
        echo "INFO: Log file location: ${log_file}"
        
        echo "----------------------------------------------------------------"
        echo "Operation completed at: $(date)"
        echo "================================================================"
        echo ""

    } 2>&1 | tee "${log_file}"

    return 0
}
##-------------------------------------------------------------------------------------

## get Aurora cluster info #
## get current engine type and engine version #

function get_aurora_cluster_info() {
    echo -e "\nINFO: Execute get_aurora_cluster_info function...\n"
    
    # Run the AWS CLI command and store the output
    cluster_info=$( ${AWS_CLI} rds describe-db-clusters --db-cluster-identifier ${current_cluster_id} --output json )
    local return_value=$?
    
    if [ "${return_value}" != "0" ]; then
        echo -e "\nERROR: Failed to retrieve Aurora cluster information for ${current_cluster_id}\n"
        exit 1
    fi
    
    # Validate cluster exists and parse basic information
    local cluster_count=$(echo $cluster_info | jq -r '.DBClusters | length')
    if [ "${cluster_count}" = "0" ]; then
        echo -e "\nERROR: Aurora cluster ${current_cluster_id} not found\n"
        exit 1
    fi

    # Parse the output and extract the required properties
    db_name=$(echo $cluster_info | jq -r '.DBClusters[0].DatabaseName')
    cluster_writer_endpoint=$(echo $cluster_info | jq -r '.DBClusters[0].Endpoint')
    cluster_reader_endpoint=$(echo $cluster_info | jq -r '.DBClusters[0].ReaderEndpoint')
    cluster_port=$(echo $cluster_info | jq -r '.DBClusters[0].Port')
    current_cluster_status=$(echo $cluster_info | jq -r '.DBClusters[0].Status' | tr '[:lower:]' '[:upper:]')
    current_engine_type=$(echo $cluster_info | jq -r '.DBClusters[0].Engine')
    current_engine_version=$(echo $cluster_info | jq -r '.DBClusters[0].EngineVersion')
    current_engine_version_family=$(echo $cluster_info | jq -r '.DBClusters[0].EngineVersion | split(".")[0:2] | join(".")')
    current_engine_version_family=$(echo "${current_engine_version_family}" | cut -d. -f1)
    current_cluster_param_group=$(echo $cluster_info | jq -r '.DBClusters[0].DBClusterParameterGroup')
    
    # Validate cluster status
    echo -e "\nINFO: Validating Aurora cluster status and availability...\n"
    if [ "${current_cluster_status}" != "AVAILABLE" ]; then
        echo -e "\nERROR: Aurora cluster ${current_cluster_id} is not in 'AVAILABLE' status. Current status: ${current_cluster_status}\n"
        echo -e "ERROR: Cluster must be in 'AVAILABLE' status before proceeding with upgrade operations.\n"
        exit 1
    fi
    
    # Get writer instance information and validate
    writer_instance_id=$(echo $cluster_info | jq -r '.DBClusters[0].DBClusterMembers[] | select(.IsClusterWriter==true) | .DBInstanceIdentifier')
    if [ -z "${writer_instance_id}" ]; then
        echo -e "\nERROR: No writer instance found in Aurora cluster ${current_cluster_id}\n"
        exit 1
    fi
    
    # Get all reader instances
    reader_instance_ids=$(echo $cluster_info | jq -r '.DBClusters[0].DBClusterMembers[] | select(.IsClusterWriter==false) | .DBInstanceIdentifier' | tr '\n' ' ')
    reader_count=$(echo $cluster_info | jq -r '.DBClusters[0].DBClusterMembers[] | select(.IsClusterWriter==false) | .DBInstanceIdentifier' | wc -l)
    
    # Get cluster endpoint (same as writer endpoint for Aurora)
    cluster_endpoint="${cluster_writer_endpoint}"
    
    # Validate all cluster instances are available
    echo -e "\nINFO: Validating Aurora cluster instance statuses...\n"
    
    # Check writer instance status and get instance parameter group
    writer_instance_status=$( ${AWS_CLI} rds describe-db-instances --db-instance-identifier ${writer_instance_id} --query 'DBInstances[0].DBInstanceStatus' --output text | tr '[:lower:]' '[:upper:]' )
    if [ "${writer_instance_status}" != "AVAILABLE" ]; then
        echo -e "\nERROR: Writer instance ${writer_instance_id} is not in 'AVAILABLE' status. Current status: ${writer_instance_status}\n"
        exit 1
    fi
    
    # Get current instance parameter group from writer instance
    current_instance_param_group=$( ${AWS_CLI} rds describe-db-instances --db-instance-identifier ${writer_instance_id} --query 'DBInstances[0].DBParameterGroups[0].DBParameterGroupName' --output text )
    if [ -z "${current_instance_param_group}" ] || [ "${current_instance_param_group}" = "null" ]; then
        echo -e "\nERROR: Unable to retrieve instance parameter group for writer instance ${writer_instance_id}\n"
        exit 1
    fi
    
    # Check reader instance statuses if any exist
    if [ "${reader_count}" -gt 0 ] && [ -n "${reader_instance_ids}" ]; then
        for reader_id in ${reader_instance_ids}; do
            if [ -n "${reader_id}" ]; then
                reader_instance_status=$( ${AWS_CLI} rds describe-db-instances --db-instance-identifier ${reader_id} --query 'DBInstances[0].DBInstanceStatus' --output text | tr '[:lower:]' '[:upper:]' )
                if [ "${reader_instance_status}" != "AVAILABLE" ]; then
                    echo -e "\nERROR: Reader instance ${reader_id} is not in 'AVAILABLE' status. Current status: ${reader_instance_status}\n"
                    exit 1
                fi
            fi
        done
    fi
    
    # Validate endpoints are accessible
    echo -e "\nINFO: Validating Aurora cluster endpoints...\n"
    if [ -z "${cluster_writer_endpoint}" ] || [ "${cluster_writer_endpoint}" = "null" ]; then
        echo -e "\nERROR: Aurora cluster writer endpoint is not available\n"
        exit 1
    fi
    
    # Set cluster endpoint variables for database operations
    export AURORA_CLUSTER_ENDPOINT="${cluster_endpoint}"
    export AURORA_WRITER_ENDPOINT="${cluster_writer_endpoint}"
    export AURORA_READER_ENDPOINT="${cluster_reader_endpoint}"
    export AURORA_WRITER_INSTANCE="${writer_instance_id}"
    
    echo -e "\nAurora Upgrade/Patching steps begin...\n"
    echo "current_cluster_id = $current_cluster_id"
    echo "current_engine_type = $current_engine_type"
    echo "current_engine_version = $current_engine_version"
    echo "current_engine_version_family = $current_engine_version_family"
    echo "current_cluster_status = $current_cluster_status"
    echo "current_cluster_param_group = $current_cluster_param_group"
    echo "current_instance_param_group = $current_instance_param_group"
    echo "writer_instance_id = $writer_instance_id"
    echo "reader_instance_ids = $reader_instance_ids"
    echo "reader_count = $reader_count"
    echo "cluster_endpoint = $cluster_endpoint"
    echo "cluster_writer_endpoint = $cluster_writer_endpoint"
    echo "cluster_reader_endpoint = $cluster_reader_endpoint"
    echo "cluster_port = $cluster_port"
    echo "cluster_snapshot_required = $cluster_snapshot_required"
    echo "cluster_parameter_modify = $cluster_parameter_modify"
    echo "instance_parameter_modify = $instance_parameter_modify"
    echo "cluster_drop_replication_slot = $cluster_drop_replication_slot"
    echo "run_pre_upg_tasks = $run_pre_upg_tasks"
    echo "db_name = ${db_name}"
    echo "S3_BUCKET_PATCH_LOGS = ${S3_BUCKET_PATCH_LOGS}"
    echo "SNS_TOPIC_ARN_EMAIL = ${SNS_TOPIC_ARN_EMAIL}"
    
    echo -e "\nINFO: Aurora cluster information gathered and validated successfully.\n"
}
##-------------------------------------------------------------------------------------

# Aurora-specific logging and error handling functions #

# Enhanced logging function for Aurora cluster context information with comprehensive details
# Note: Basic version defined earlier for early script usage
function log_aurora_cluster_context_enhanced() {
    local log_level="${1:-INFO}"
    local message="${2:-}"
    local operation="${3:-general}"
    local additional_context="${4:-}"
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local cluster_context=""
    local extended_context=""
    
    # Build comprehensive Aurora cluster context information
    if [ -n "${current_cluster_id}" ]; then
        cluster_context="[Aurora-Cluster:${current_cluster_id}]"
        
        # Add writer instance if available
        if [ -n "${writer_instance_id}" ]; then
            cluster_context="${cluster_context}[Writer:${writer_instance_id}]"
        fi
        
        # Add current engine version if available
        if [ -n "${current_engine_version}" ]; then
            cluster_context="${cluster_context}[Version:${current_engine_version}]"
        fi
        
        # Add target version if available and different from current
        if [ -n "${next_engine_version}" ] && [ "${next_engine_version}" != "${current_engine_version}" ]; then
            cluster_context="${cluster_context}[Target:${next_engine_version}]"
        fi
        
        # Add upgrade scope if available
        if [ -n "${UPGRADE_SCOPE}" ]; then
            cluster_context="${cluster_context}[Scope:${UPGRADE_SCOPE}]"
        fi
        
        # Add operation context
        if [ -n "${operation}" ] && [ "${operation}" != "general" ]; then
            cluster_context="${cluster_context}[Op:${operation}]"
        fi
        
        # Add workflow phase context
        if [ -n "${run_pre_upg_tasks}" ]; then
            cluster_context="${cluster_context}[Phase:${run_pre_upg_tasks}]"
        fi
        
        # Add additional context if provided
        if [ -n "${additional_context}" ]; then
            extended_context="[Context:${additional_context}]"
        fi
    else
        cluster_context="[Aurora-Cluster:unknown]"
    fi
    
    # Format and output the log message with enhanced context
    local full_message="${timestamp} ${log_level}: ${cluster_context}${extended_context} ${message}"
    echo "${full_message}"
    
    # Enhanced logging to multiple destinations
    if [ -n "${LOGS_DIR}" ] && [ -d "${LOGS_DIR}" ]; then
        # Create cluster-specific log directory if it doesn't exist
        local cluster_log_dir="${LOGS_DIR}/${current_cluster_id:-unknown}"
        mkdir -p "${cluster_log_dir}" 2>/dev/null
        
        # Log to main operations file
        echo "${full_message}" >> "${cluster_log_dir}/aurora-cluster-operations.log" 2>/dev/null
        
        # Log to operation-specific file if operation is specified
        if [ -n "${operation}" ] && [ "${operation}" != "general" ]; then
            echo "${full_message}" >> "${cluster_log_dir}/aurora-${operation}.log" 2>/dev/null
        fi
        
        # Log to level-specific file for errors and warnings
        case "${log_level}" in
            "ERROR"|"WARN"|"WARNING")
                echo "${full_message}" >> "${cluster_log_dir}/aurora-cluster-issues.log" 2>/dev/null
                ;;
        esac
    fi
}

# Function to log Aurora cluster errors with comprehensive context and diagnostics
function log_aurora_error() {
    local error_message="${1:-Unknown error occurred}"
    local error_code="${2:-1}"
    local operation="${3:-unknown}"
    local recovery_suggestion="${4:-Please check Aurora cluster status and logs}"
    local error_category="${5:-general}"
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local error_id="ERR-$(date +%s)-$$"
    
    # Log primary error with enhanced context
    log_aurora_cluster_context "ERROR" "${error_message}" "${operation}" "ErrorID:${error_id}"
    log_aurora_cluster_context "ERROR" "Error Code: ${error_code} | Category: ${error_category}" "${operation}" "ErrorID:${error_id}"
    log_aurora_cluster_context "ERROR" "Recovery Suggestion: ${recovery_suggestion}" "${operation}" "ErrorID:${error_id}"
    
    # Collect comprehensive Aurora cluster diagnostics
    local cluster_diagnostics=""
    local instance_diagnostics=""
    
    if [ -n "${current_cluster_id}" ]; then
        # Get detailed cluster status and configuration
        local cluster_info=$( ${AWS_CLI} rds describe-db-clusters --db-cluster-identifier ${current_cluster_id} --query 'DBClusters[0].{Status:Status,Engine:Engine,EngineVersion:EngineVersion,MultiAZ:MultiAZ,ClusterCreateTime:ClusterCreateTime,BackupRetentionPeriod:BackupRetentionPeriod}' --output json 2>/dev/null )
        
        if [ -n "${cluster_info}" ] && [ "${cluster_info}" != "null" ]; then
            local cluster_status=$(echo "${cluster_info}" | jq -r '.Status // "unknown"' 2>/dev/null | tr '[:lower:]' '[:upper:]')
            local cluster_engine=$(echo "${cluster_info}" | jq -r '.Engine // "unknown"' 2>/dev/null)
            local cluster_version=$(echo "${cluster_info}" | jq -r '.EngineVersion // "unknown"' 2>/dev/null)
            local cluster_multiaz=$(echo "${cluster_info}" | jq -r '.MultiAZ // "unknown"' 2>/dev/null)
            
            log_aurora_cluster_context "ERROR" "Cluster Status: ${cluster_status} | Engine: ${cluster_engine} ${cluster_version} | MultiAZ: ${cluster_multiaz}" "${operation}" "ErrorID:${error_id}"
            
            cluster_diagnostics="Status:${cluster_status},Engine:${cluster_engine},Version:${cluster_version},MultiAZ:${cluster_multiaz}"
        else
            log_aurora_cluster_context "ERROR" "Unable to retrieve cluster information - cluster may not exist or be inaccessible" "${operation}" "ErrorID:${error_id}"
            cluster_diagnostics="Status:inaccessible"
        fi
        
        # Get detailed cluster member status and health
        local cluster_members=$( ${AWS_CLI} rds describe-db-clusters --db-cluster-identifier ${current_cluster_id} --query 'DBClusters[0].DBClusterMembers[]' --output json 2>/dev/null )
        
        if [ -n "${cluster_members}" ] && [ "${cluster_members}" != "null" ] && [ "${cluster_members}" != "[]" ]; then
            log_aurora_cluster_context "ERROR" "Analyzing cluster member instances:" "${operation}" "ErrorID:${error_id}"
            
            echo "${cluster_members}" | jq -r '.[] | "\(.DBInstanceIdentifier) \(.IsClusterWriter)"' 2>/dev/null | while read instance_id is_writer; do
                if [ -n "${instance_id}" ]; then
                    local instance_info=$( ${AWS_CLI} rds describe-db-instances --db-instance-identifier ${instance_id} --query 'DBInstances[0].{Status:DBInstanceStatus,Class:DBInstanceClass,AZ:AvailabilityZone,PendingMaintenance:PendingModifiedValues}' --output json 2>/dev/null )
                    
                    if [ -n "${instance_info}" ] && [ "${instance_info}" != "null" ]; then
                        local instance_status=$(echo "${instance_info}" | jq -r '.Status // "unknown"' 2>/dev/null | tr '[:lower:]' '[:upper:]')
                        local instance_class=$(echo "${instance_info}" | jq -r '.Class // "unknown"' 2>/dev/null)
                        local instance_az=$(echo "${instance_info}" | jq -r '.AZ // "unknown"' 2>/dev/null)
                        
                        local role_text="Reader"
                        if [ "${is_writer}" = "true" ]; then
                            role_text="Writer"
                        fi
                        
                        log_aurora_cluster_context "ERROR" "  ${role_text} Instance ${instance_id}: Status=${instance_status}, Class=${instance_class}, AZ=${instance_az}" "${operation}" "ErrorID:${error_id}"
                        
                        # Check for pending maintenance or modifications
                        local pending_changes=$(echo "${instance_info}" | jq -r '.PendingMaintenance // empty' 2>/dev/null)
                        if [ -n "${pending_changes}" ] && [ "${pending_changes}" != "null" ] && [ "${pending_changes}" != "{}" ]; then
                            log_aurora_cluster_context "ERROR" "    Pending changes detected on ${instance_id}" "${operation}" "ErrorID:${error_id}"
                        fi
                        
                        instance_diagnostics="${instance_diagnostics}${instance_id}:${instance_status},"
                    fi
                fi
            done
        else
            log_aurora_cluster_context "ERROR" "No cluster members found or unable to retrieve member information" "${operation}" "ErrorID:${error_id}"
        fi
        
        # Check for recent cluster events that might be related to the error
        local recent_events=$( ${AWS_CLI} rds describe-events --source-identifier ${current_cluster_id} --source-type db-cluster --start-time $(date -d '1 hour ago' -u +%Y-%m-%dT%H:%M:%S) --query 'Events[?EventCategories[?contains(@, `failure`) || contains(@, `maintenance`) || contains(@, `configuration change`)]].[Date,Message]' --output text 2>/dev/null )
        
        if [ -n "${recent_events}" ]; then
            log_aurora_cluster_context "ERROR" "Recent cluster events that may be related:" "${operation}" "ErrorID:${error_id}"
            echo "${recent_events}" | head -5 | while IFS=$'\t' read event_date event_message; do
                if [ -n "${event_date}" ] && [ -n "${event_message}" ]; then
                    log_aurora_cluster_context "ERROR" "  ${event_date}: ${event_message}" "${operation}" "ErrorID:${error_id}"
                fi
            done
        fi
    fi
    
    # Create comprehensive error report
    if [ -n "${LOGS_DIR}" ] && [ -d "${LOGS_DIR}" ]; then
        local cluster_log_dir="${LOGS_DIR}/${current_cluster_id:-unknown}"
        mkdir -p "${cluster_log_dir}" 2>/dev/null
        
        {
            echo "=== Aurora Cluster Error Report ==="
            echo "Error ID: ${error_id}"
            echo "Timestamp: ${timestamp}"
            echo "Cluster ID: ${current_cluster_id:-unknown}"
            echo "Operation: ${operation}"
            echo "Error Category: ${error_category}"
            echo "Error Message: ${error_message}"
            echo "Error Code: ${error_code}"
            echo "Recovery Suggestion: ${recovery_suggestion}"
            echo ""
            echo "=== Cluster Diagnostics ==="
            echo "Cluster Info: ${cluster_diagnostics:-unavailable}"
            echo "Instance Info: ${instance_diagnostics:-unavailable}"
            echo ""
            echo "=== Environment Context ==="
            echo "Upgrade Phase: ${run_pre_upg_tasks:-unknown}"
            echo "Upgrade Scope: ${UPGRADE_SCOPE:-unknown}"
            echo "Current Version: ${current_engine_version:-unknown}"
            echo "Target Version: ${next_engine_version:-unknown}"
            echo "Script PID: $$"
            echo "AWS CLI Version: $(${AWS_CLI} --version 2>/dev/null | head -1 || echo 'unknown')"
            echo ""
            echo "=== Troubleshooting Commands ==="
            echo "Check cluster status: aws rds describe-db-clusters --db-cluster-identifier ${current_cluster_id}"
            echo "Check cluster events: aws rds describe-events --source-identifier ${current_cluster_id} --source-type db-cluster"
            echo "Check cluster logs: aws logs describe-log-groups --log-group-name-prefix /aws/rds/cluster/${current_cluster_id}"
            echo "=================================="
            echo ""
        } >> "${cluster_log_dir}/aurora-cluster-errors.log" 2>/dev/null
        
        # Also create a structured JSON error log for automated processing
        {
            echo "{"
            echo "  \"error_id\": \"${error_id}\","
            echo "  \"timestamp\": \"${timestamp}\","
            echo "  \"cluster_id\": \"${current_cluster_id:-unknown}\","
            echo "  \"operation\": \"${operation}\","
            echo "  \"error_category\": \"${error_category}\","
            echo "  \"error_message\": \"$(echo "${error_message}" | sed 's/"/\\"/g')\","
            echo "  \"error_code\": ${error_code},"
            echo "  \"recovery_suggestion\": \"$(echo "${recovery_suggestion}" | sed 's/"/\\"/g')\","
            echo "  \"cluster_diagnostics\": \"${cluster_diagnostics:-unavailable}\","
            echo "  \"instance_diagnostics\": \"${instance_diagnostics:-unavailable}\","
            echo "  \"upgrade_phase\": \"${run_pre_upg_tasks:-unknown}\","
            echo "  \"upgrade_scope\": \"${UPGRADE_SCOPE:-unknown}\","
            echo "  \"current_version\": \"${current_engine_version:-unknown}\","
            echo "  \"target_version\": \"${next_engine_version:-unknown}\""
            echo "},"
        } >> "${cluster_log_dir}/aurora-cluster-errors.json" 2>/dev/null
    fi
    
    # Create structured log entry for this error
    local error_metadata="{\"error_id\":\"${error_id}\",\"error_code\":${error_code},\"error_category\":\"${error_category}\",\"cluster_diagnostics\":\"${cluster_diagnostics:-unavailable}\"}"
    create_aurora_log_entry "${operation}" "error" "${error_message}" "${error_metadata}"
}

# Function to log Aurora cluster operation start with enhanced tracking
function log_aurora_operation_start() {
    local operation="${1:-unknown}"
    local details="${2:-}"
    local expected_duration="${3:-}"
    
    local operation_id="OP-$(date +%s)-$$"
    local start_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    log_aurora_cluster_context "INFO" "Starting ${operation} operation" "${operation}" "OpID:${operation_id}"
    
    if [ -n "${details}" ]; then
        log_aurora_cluster_context "INFO" "Operation details: ${details}" "${operation}" "OpID:${operation_id}"
    fi
    
    if [ -n "${expected_duration}" ]; then
        log_aurora_cluster_context "INFO" "Expected duration: ${expected_duration}" "${operation}" "OpID:${operation_id}"
    fi
    
    # Enhanced operation tracking with metadata
    local tracking_dir="/tmp/aurora_operations"
    mkdir -p "${tracking_dir}" 2>/dev/null
    
    local tracking_file="${tracking_dir}/aurora_op_${operation}_${current_cluster_id}_${operation_id}"
    
    # Store comprehensive operation metadata
    {
        echo "OPERATION_ID=${operation_id}"
        echo "OPERATION_NAME=${operation}"
        echo "CLUSTER_ID=${current_cluster_id}"
        echo "START_TIME=$(date +%s)"
        echo "START_TIMESTAMP=${start_timestamp}"
        echo "DETAILS=${details}"
        echo "EXPECTED_DURATION=${expected_duration}"
        echo "UPGRADE_PHASE=${run_pre_upg_tasks}"
        echo "UPGRADE_SCOPE=${UPGRADE_SCOPE}"
        echo "CURRENT_VERSION=${current_engine_version}"
        echo "TARGET_VERSION=${next_engine_version}"
        echo "PID=$$"
    } > "${tracking_file}" 2>/dev/null
    
    # Log operation start in structured format
    local start_metadata="{\"operation_id\":\"${operation_id}\",\"expected_duration\":\"${expected_duration}\",\"start_timestamp\":\"${start_timestamp}\"}"
    create_aurora_log_entry "${operation}" "started" "Operation ${operation} initiated" "${start_metadata}"
    
    # Store operation ID for later reference
    echo "${operation_id}" > "/tmp/aurora_current_op_${operation}_${current_cluster_id}" 2>/dev/null
}

# Function to log Aurora cluster operation completion with comprehensive metrics
function log_aurora_operation_complete() {
    local operation="${1:-unknown}"
    local status="${2:-success}"
    local details="${3:-}"
    local performance_metrics="${4:-}"
    
    local end_timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local end_time=$(date +%s)
    
    # Retrieve operation ID and metadata
    local operation_id=""
    local duration_info=""
    local start_timestamp=""
    local expected_duration=""
    
    local current_op_file="/tmp/aurora_current_op_${operation}_${current_cluster_id}"
    if [ -f "${current_op_file}" ]; then
        operation_id=$(cat "${current_op_file}" 2>/dev/null)
        rm -f "${current_op_file}" 2>/dev/null
    fi
    
    # Get detailed operation tracking information
    local tracking_dir="/tmp/aurora_operations"
    local tracking_file="${tracking_dir}/aurora_op_${operation}_${current_cluster_id}_${operation_id}"
    
    if [ -f "${tracking_file}" ]; then
        # Source the tracking file to get operation metadata
        source "${tracking_file}" 2>/dev/null
        
        if [ -n "${START_TIME}" ] && [ "${START_TIME}" -gt 0 ]; then
            local duration=$((end_time - START_TIME))
            local duration_minutes=$((duration / 60))
            local duration_seconds=$((duration % 60))
            
            if [ ${duration_minutes} -gt 0 ]; then
                duration_info=" (Duration: ${duration_minutes}m ${duration_seconds}s)"
            else
                duration_info=" (Duration: ${duration}s)"
            fi
            
            # Compare with expected duration if available
            if [ -n "${EXPECTED_DURATION}" ] && [ "${EXPECTED_DURATION}" != "" ]; then
                duration_info="${duration_info} [Expected: ${EXPECTED_DURATION}]"
            fi
        fi
        
        start_timestamp="${START_TIMESTAMP}"
        expected_duration="${EXPECTED_DURATION}"
        
        # Clean up tracking file
        rm -f "${tracking_file}" 2>/dev/null
    else
        # Fallback to legacy tracking method
        local legacy_start_file="/tmp/aurora_op_start_${operation}_${current_cluster_id}"
        if [ -f "${legacy_start_file}" ]; then
            local start_time=$(cat "${legacy_start_file}" 2>/dev/null)
            if [ -n "${start_time}" ] && [ "${start_time}" -gt 0 ]; then
                local duration=$((end_time - start_time))
                duration_info=" (Duration: ${duration}s)"
            fi
            rm -f "${legacy_start_file}" 2>/dev/null
        fi
    fi
    
    # Determine log level based on status
    local log_level="INFO"
    case "${status}" in
        "success"|"completed"|"ok")
            log_level="INFO"
            ;;
        "warning"|"partial"|"degraded")
            log_level="WARN"
            ;;
        "error"|"failed"|"timeout"|"aborted")
            log_level="ERROR"
            ;;
        *)
            log_level="INFO"
            ;;
    esac
    
    # Log completion with enhanced context
    local context_info="OpID:${operation_id:-unknown}"
    log_aurora_cluster_context "${log_level}" "${operation} operation completed with status: ${status}${duration_info}" "${operation}" "${context_info}"
    
    if [ -n "${details}" ]; then
        log_aurora_cluster_context "${log_level}" "Completion details: ${details}" "${operation}" "${context_info}"
    fi
    
    if [ -n "${performance_metrics}" ]; then
        log_aurora_cluster_context "${log_level}" "Performance metrics: ${performance_metrics}" "${operation}" "${context_info}"
    fi
    
    # Log operation summary for successful operations
    if [ "${status}" = "success" ] || [ "${status}" = "completed" ]; then
        log_aurora_cluster_context "INFO" "Operation ${operation} completed successfully${duration_info}" "${operation}" "${context_info}"
        
        # Log resource state after successful operation
        if [ -n "${current_cluster_id}" ]; then
            local post_op_status=$( ${AWS_CLI} rds describe-db-clusters --db-cluster-identifier ${current_cluster_id} --query 'DBClusters[0].Status' --output text 2>/dev/null )
            if [ -n "${post_op_status}" ]; then
                log_aurora_cluster_context "INFO" "Post-operation cluster status: ${post_op_status}" "${operation}" "${context_info}"
            fi
        fi
    fi
    
    # Create comprehensive completion log entry
    local completion_metadata="{"
    completion_metadata="${completion_metadata}\"operation_id\":\"${operation_id:-unknown}\""
    completion_metadata="${completion_metadata},\"start_timestamp\":\"${start_timestamp:-unknown}\""
    completion_metadata="${completion_metadata},\"end_timestamp\":\"${end_timestamp}\""
    completion_metadata="${completion_metadata},\"duration_seconds\":$((end_time - ${START_TIME:-end_time}))"
    completion_metadata="${completion_metadata},\"expected_duration\":\"${expected_duration:-unknown}\""
    
    if [ -n "${performance_metrics}" ]; then
        completion_metadata="${completion_metadata},\"performance_metrics\":\"${performance_metrics}\""
    fi
    
    completion_metadata="${completion_metadata}}"
    
    create_aurora_log_entry "${operation}" "${status}" "Operation ${operation} completed" "${completion_metadata}"
    
    # Log operation summary to dedicated operations log
    if [ -n "${LOGS_DIR}" ] && [ -d "${LOGS_DIR}" ]; then
        local cluster_log_dir="${LOGS_DIR}/${current_cluster_id:-unknown}"
        mkdir -p "${cluster_log_dir}" 2>/dev/null
        
        {
            echo "=== Operation Summary ==="
            echo "Operation: ${operation}"
            echo "Operation ID: ${operation_id:-unknown}"
            echo "Status: ${status}"
            echo "Start Time: ${start_timestamp:-unknown}"
            echo "End Time: ${end_timestamp}"
            echo "Duration: ${duration_info:-unknown}"
            echo "Details: ${details:-none}"
            echo "Performance Metrics: ${performance_metrics:-none}"
            echo "========================="
            echo ""
        } >> "${cluster_log_dir}/aurora-operations-summary.log" 2>/dev/null
    fi
}

# Function to generate comprehensive Aurora upgrade session summary
function generate_aurora_session_summary() {
    local session_status="${1:-completed}"
    local session_details="${2:-}"
    
    if [ -z "${LOGS_DIR}" ] || [ ! -d "${LOGS_DIR}" ]; then
        return 0
    fi
    
    local cluster_log_dir="${LOGS_DIR}/${current_cluster_id:-unknown}"
    mkdir -p "${cluster_log_dir}" 2>/dev/null
    
    local summary_file="${cluster_log_dir}/aurora-session-summary.log"
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    
    {
        echo "========================================"
        echo "Aurora PostgreSQL Upgrade Session Summary"
        echo "========================================"
        echo "Session Timestamp: ${timestamp}"
        echo "Cluster ID: ${current_cluster_id:-unknown}"
        echo "Session Status: ${session_status}"
        echo ""
        echo "=== Upgrade Configuration ==="
        echo "Current Engine Version: ${current_engine_version:-unknown}"
        echo "Target Engine Version: ${next_engine_version:-unknown}"
        echo "Engine Type: ${current_engine_type:-unknown}"
        echo "Upgrade Scope: ${UPGRADE_SCOPE:-unknown}"
        echo "Upgrade Phase: ${run_pre_upg_tasks:-unknown}"
        echo "Writer Instance: ${writer_instance_id:-unknown}"
        echo ""
        echo "=== Parameter Groups ==="
        echo "Cluster Parameter Group: ${cluster_param_group_name:-none}"
        echo "Instance Parameter Group: ${instance_param_group_name:-none}"
        echo ""
        echo "=== Environment ==="
        echo "Script PID: $$"
        echo "Hostname: $(hostname 2>/dev/null || echo 'unknown')"
        echo "Username: $(whoami 2>/dev/null || echo 'unknown')"
        echo "AWS Region: ${AWS_DEFAULT_REGION:-unknown}"
        echo "AWS CLI Version: $(${AWS_CLI} --version 2>/dev/null | head -1 || echo 'unknown')"
        echo ""
        echo "=== Session Details ==="
        echo "${session_details:-No additional details provided}"
        echo ""
        echo "=== Log Files Generated ==="
        if [ -d "${cluster_log_dir}" ]; then
            find "${cluster_log_dir}" -name "*.log" -type f -exec basename {} \; | sort
        fi
        echo ""
        echo "========================================"
        echo "End of Session Summary"
        echo "========================================"
        echo ""
    } > "${summary_file}"
    
    log_aurora_cluster_context "INFO" "Aurora upgrade session summary generated: ${summary_file}" "session_summary"
    create_aurora_log_entry "session_summary" "generated" "Session summary created" "{\"summary_file\":\"${summary_file}\"}"
}

# Function to validate Aurora cluster state before operations
function validate_aurora_cluster_state() {
    local operation="${1:-unknown}"
    local required_status="${2:-available}"
    
    log_aurora_cluster_context "INFO" "Validating Aurora cluster state for ${operation}" "${operation}"
    
    # Check if cluster exists and get status
    local cluster_status=$( ${AWS_CLI} rds describe-db-clusters --db-cluster-identifier ${current_cluster_id} --query 'DBClusters[0].Status' --output text 2>/dev/null )
    local return_code=$?
    
    if [ ${return_code} -ne 0 ] || [ -z "${cluster_status}" ]; then
        log_aurora_error "Aurora cluster ${current_cluster_id} not found or inaccessible" "${return_code}" "${operation}" "Verify cluster identifier and AWS permissions"
        return 1
    fi
    
    # Check cluster status
    if [ "${cluster_status}" != "${required_status}" ]; then
        log_aurora_error "Aurora cluster ${current_cluster_id} is not in required state. Current: ${cluster_status}, Required: ${required_status}" "2" "${operation}" "Wait for cluster to reach ${required_status} state before proceeding"
        return 1
    fi
    
    # Validate all cluster instances are in available state
    local cluster_instances=$( ${AWS_CLI} rds describe-db-clusters --db-cluster-identifier ${current_cluster_id} --query 'DBClusters[0].DBClusterMembers[].DBInstanceIdentifier' --output text 2>/dev/null )
    
    for instance_id in ${cluster_instances}; do
        if [ -n "${instance_id}" ]; then
            local instance_status=$( ${AWS_CLI} rds describe-db-instances --db-instance-identifier ${instance_id} --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null | tr '[:lower:]' '[:upper:]' )
            
            if [ "${instance_status}" != "AVAILABLE" ]; then
                log_aurora_error "Aurora cluster instance ${instance_id} is not available. Status: ${instance_status}" "3" "${operation}" "Wait for all cluster instances to be available before proceeding"
                return 1
            fi
        fi
    done
    
    log_aurora_cluster_context "INFO" "Aurora cluster state validation successful" "${operation}"
    return 0
}

# Enhanced function to create comprehensive structured log entry for Aurora operations
# Note: Basic version defined earlier for early script usage
function create_aurora_log_entry_enhanced() {
    local operation="${1:-unknown}"
    local status="${2:-unknown}"
    local message="${3:-}"
    local metadata="${4:-}"
    local log_level="${5:-INFO}"
    
    local timestamp=$(date '+%Y-%m-%d %H:%M:%S')
    local iso_timestamp=$(date -u '+%Y-%m-%dT%H:%M:%S.%3NZ')
    local epoch_timestamp=$(date +%s)
    
    # Create comprehensive structured log entry with enhanced Aurora context
    local log_entry="{"
    log_entry="${log_entry}\"timestamp\":\"${timestamp}\""
    log_entry="${log_entry},\"iso_timestamp\":\"${iso_timestamp}\""
    log_entry="${log_entry},\"epoch_timestamp\":${epoch_timestamp}"
    log_entry="${log_entry},\"log_level\":\"${log_level}\""
    log_entry="${log_entry},\"cluster_id\":\"${current_cluster_id:-unknown}\""
    log_entry="${log_entry},\"operation\":\"${operation}\""
    log_entry="${log_entry},\"status\":\"${status}\""
    
    # Add message with proper escaping
    if [ -n "${message}" ]; then
        local escaped_message=$(echo "${message}" | sed 's/"/\\"/g' | sed 's/\\/\\\\/g' | tr -d '\n\r')
        log_entry="${log_entry},\"message\":\"${escaped_message}\""
    fi
    
    # Add Aurora cluster context information
    if [ -n "${current_engine_version}" ]; then
        log_entry="${log_entry},\"current_engine_version\":\"${current_engine_version}\""
    fi
    
    if [ -n "${next_engine_version}" ]; then
        log_entry="${log_entry},\"target_engine_version\":\"${next_engine_version}\""
    fi
    
    if [ -n "${current_engine_type}" ]; then
        log_entry="${log_entry},\"engine_type\":\"${current_engine_type}\""
    fi
    
    if [ -n "${writer_instance_id}" ]; then
        log_entry="${log_entry},\"writer_instance_id\":\"${writer_instance_id}\""
    fi
    
    if [ -n "${UPGRADE_SCOPE}" ]; then
        log_entry="${log_entry},\"upgrade_scope\":\"${UPGRADE_SCOPE}\""
    fi
    
    if [ -n "${run_pre_upg_tasks}" ]; then
        log_entry="${log_entry},\"upgrade_phase\":\"${run_pre_upg_tasks}\""
    fi
    
    # Add cluster configuration context
    if [ -n "${cluster_param_group_name}" ]; then
        log_entry="${log_entry},\"cluster_parameter_group\":\"${cluster_param_group_name}\""
    fi
    
    if [ -n "${instance_param_group_name}" ]; then
        log_entry="${log_entry},\"instance_parameter_group\":\"${instance_param_group_name}\""
    fi
    
    # Add environment and execution context
    log_entry="${log_entry},\"script_pid\":$$"
    log_entry="${log_entry},\"aws_region\":\"${AWS_DEFAULT_REGION:-unknown}\""
    
    # Add hostname and user context for traceability
    local hostname=$(hostname 2>/dev/null || echo "unknown")
    local username=$(whoami 2>/dev/null || echo "unknown")
    log_entry="${log_entry},\"hostname\":\"${hostname}\""
    log_entry="${log_entry},\"username\":\"${username}\""
    
    # Add custom metadata if provided
    if [ -n "${metadata}" ]; then
        # Validate that metadata is valid JSON
        if echo "${metadata}" | jq . >/dev/null 2>&1; then
            log_entry="${log_entry},\"custom_metadata\":${metadata}"
        else
            # If not valid JSON, treat as string
            local escaped_metadata=$(echo "${metadata}" | sed 's/"/\\"/g' | tr -d '\n\r')
            log_entry="${log_entry},\"custom_metadata\":\"${escaped_metadata}\""
        fi
    fi
    
    # Add AWS CLI version for troubleshooting
    local aws_cli_version=$(${AWS_CLI} --version 2>/dev/null | head -1 | cut -d' ' -f1-2 || echo "unknown")
    log_entry="${log_entry},\"aws_cli_version\":\"${aws_cli_version}\""
    
    log_entry="${log_entry}}"
    
    # Output structured log to stdout
    echo "${log_entry}"
    
    # Save to multiple structured log destinations
    if [ -n "${LOGS_DIR}" ] && [ -d "${LOGS_DIR}" ]; then
        local cluster_log_dir="${LOGS_DIR}/${current_cluster_id:-unknown}"
        mkdir -p "${cluster_log_dir}" 2>/dev/null
        
        # Main structured log file
        echo "${log_entry}" >> "${cluster_log_dir}/aurora-cluster-structured.log" 2>/dev/null
        
        # Operation-specific structured log
        if [ "${operation}" != "unknown" ]; then
            echo "${log_entry}" >> "${cluster_log_dir}/aurora-${operation}-structured.log" 2>/dev/null
        fi
        
        # Status-specific logs for easier filtering
        case "${status}" in
            "error"|"failed"|"timeout"|"aborted")
                echo "${log_entry}" >> "${cluster_log_dir}/aurora-errors-structured.log" 2>/dev/null
                ;;
            "warning"|"partial"|"degraded")
                echo "${log_entry}" >> "${cluster_log_dir}/aurora-warnings-structured.log" 2>/dev/null
                ;;
            "success"|"completed"|"started")
                echo "${log_entry}" >> "${cluster_log_dir}/aurora-operations-structured.log" 2>/dev/null
                ;;
        esac
        
        # Daily log rotation - create date-specific log file
        local date_suffix=$(date '+%Y-%m-%d')
        echo "${log_entry}" >> "${cluster_log_dir}/aurora-daily-${date_suffix}.log" 2>/dev/null
    fi
}

# Function to log Aurora cluster performance metrics
function log_aurora_performance_metrics() {
    local operation="${1:-unknown}"
    local metrics="${2:-}"
    local additional_context="${3:-}"
    
    if [ -z "${metrics}" ]; then
        return 0
    fi
    
    log_aurora_cluster_context "INFO" "Performance metrics for ${operation}: ${metrics}" "${operation}" "Metrics"
    
    if [ -n "${additional_context}" ]; then
        log_aurora_cluster_context "INFO" "Additional context: ${additional_context}" "${operation}" "Metrics"
    fi
    
    # Create structured performance log entry
    local perf_metadata="{\"metrics\":\"${metrics}\",\"additional_context\":\"${additional_context}\"}"
    create_aurora_log_entry "${operation}" "metrics" "Performance metrics collected" "${perf_metadata}" "INFO"
}

# Function to log Aurora cluster configuration changes
function log_aurora_configuration_change() {
    local component="${1:-unknown}"
    local change_type="${2:-unknown}"
    local old_value="${3:-}"
    local new_value="${4:-}"
    local operation="${5:-configuration}"
    
    local change_message="Configuration change in ${component}: ${change_type}"
    if [ -n "${old_value}" ] && [ -n "${new_value}" ]; then
        change_message="${change_message} (${old_value} -> ${new_value})"
    elif [ -n "${new_value}" ]; then
        change_message="${change_message} (set to: ${new_value})"
    fi
    
    log_aurora_cluster_context "INFO" "${change_message}" "${operation}" "ConfigChange"
    
    # Create structured configuration change log
    local config_metadata="{"
    config_metadata="${config_metadata}\"component\":\"${component}\""
    config_metadata="${config_metadata},\"change_type\":\"${change_type}\""
    config_metadata="${config_metadata},\"old_value\":\"${old_value}\""
    config_metadata="${config_metadata},\"new_value\":\"${new_value}\""
    config_metadata="${config_metadata}}"
    
    create_aurora_log_entry "${operation}" "config_change" "${change_message}" "${config_metadata}" "INFO"
}

##-------------------------------------------------------------------------------------

echo ""

##-------------------------------------------------------------------------------------
##------------------------EXECUTE AURORA POSTGRESQL UPGRADE/PATCHING TASKS----------------
##-------------------------------------------------------------------------------------

# Check for unix functions #
check_required_utils || exit 1

# validate next engine version for numeric #
next_engine_version=$(echo "${next_engine_version}" | bc) || {
    echo -e "\nERROR: Invalid version number format: ${next_engine_version} \n"
    exit 1
}

# run upgrade only when Aurora cluster status is available and there are no pending maintenance tasks #
current_cluster_status=$( ${AWS_CLI} rds describe-db-clusters --db-cluster-identifier ${current_cluster_id} --query 'DBClusters[0].[Status]' --output text | tr '[:lower:]' '[:upper:]' )
echo "InitialAuroraClusterStatus = ${current_cluster_status}"
if [ "${current_cluster_status}" != "AVAILABLE" ]; then

   log_aurora_error "Invalid Aurora Cluster-ID or Aurora Cluster status is NOT AVAILABLE. Upgrade cannot proceed." "1" "initialization" "Verify cluster identifier and ensure cluster is in 'available' state" "cluster_validation"
   exit 1

fi

##-------------------------------------------------------------------------------------
# mkdir for logs #
mkdir -p ${LOGS_DIR}/${current_cluster_id}

##-------------------------------------------------------------------------------------
## Call function to get Aurora cluster info #
log_aurora_operation_start "cluster_info_gathering" "Retrieving Aurora cluster information and validating configuration"
get_aurora_cluster_info
log_aurora_operation_complete "cluster_info_gathering" "success" "Aurora cluster information retrieved successfully"

##-------------------------------------------------------------------------------------
# Check Aurora cluster engine type and version to create new parameter groups #
# DBEngine = aurora-postgresql #
if [ "${current_engine_type}" = "aurora-postgresql" ]; then

    # call function to check if the next-engine-version is valid for the current aurora-postgresql cluster version #
    check_aurora_upgrade_version "${current_cluster_id}" "${next_engine_version}" || {
        echo -e "\nERROR: Please select a valid upgrade version and try again. \n"
        exit 1
    }

    # call function to check if upgrade/patching path is MINOR or MAJOR #
    check_aurora_upgrade_type

    ### Run PreReq tasks one or few hours prior to the Aurora cluster patching/upgrade #
    ## Take Aurora cluster snapshot (MINOR upgrades only - MAJOR upgrades have automatic snapshots)
    ## Create Aurora cluster parameter group ONLY for major version upgrade
    ## Create Aurora instance parameter group ONLY for major version upgrade
    ## Check replication slots if major version upgrade
    ## Run Freeze on Aurora writer endpoint
    if [ "${run_pre_upg_tasks}" = "PREUPGRADE" ]; then

        # Step 1: Take manual snapshot FIRST (before any database changes) - MINOR upgrades only
        if [ "${UPGRADE_SCOPE}" = "MINOR" ]; then
            log_aurora_cluster_context "INFO" "UPGRADE_SCOPE = ${UPGRADE_SCOPE}" "preupgrade" "MinorUpgrade"
            log_aurora_cluster_context "INFO" "Taking manual snapshot for minor upgrade (before any database changes)" "preupgrade" "MinorUpgrade"
            
            # Take snapshot FIRST for minor upgrades
            cluster_snapshot
            
            # Set parameter group names to current/existing ones for minor upgrades
            cluster_param_group_name="${current_cluster_param_group}"
            instance_param_group_name="${current_instance_param_group}"
            
            echo "INFO: Using existing cluster parameter group: ${cluster_param_group_name}"
            echo "INFO: Using existing instance parameter group: ${instance_param_group_name}"
        else
            # Step 1: For MAJOR upgrades - Take manual snapshot during PREUPGRADE phase
            log_aurora_cluster_context "INFO" "UPGRADE_SCOPE = ${UPGRADE_SCOPE}" "preupgrade" "MajorUpgrade"
            log_aurora_cluster_context "INFO" "Taking manual snapshot for major upgrade during PREUPGRADE phase" "preupgrade" "MajorUpgrade"
            log_aurora_cluster_context "INFO" "Executing major version upgrade pre-requisite tasks" "preupgrade" "MajorUpgrade"

            # Take snapshot FIRST for major upgrades during PREUPGRADE
            cluster_snapshot

            # Step 2: Create NEW parameter groups for major upgrades
            create_cluster_param_group
            create_instance_param_group
            
            # Validate parameter group assignment for major upgrade
            echo -e "\nINFO: Validating parameter group assignment for major upgrade...\n"
            determine_parameter_group_assignment "major" "false"

            # Step 3: Handle replication slots for major upgrades
            run_psql_drop_repl_slot
        fi

        # Step 4: Run Freeze on Aurora cluster writer endpoint (LAST step before upgrade)
        run_psql_command_aurora "FREEZE"

    else # run_pre_upg_tasks = UPGRADE; perform upgrade/patching tasks

        # Step 1: Create Aurora cluster clone (copy-on-write) before any database changes
        log_aurora_cluster_context "INFO" "Creating copy-on-write clone before ${UPGRADE_SCOPE} upgrade operations" "upgrade" "CloneCreation"
        cluster_clone

        # For UPGRADE phase, determine parameter group strategy based on upgrade scope
        if [ "${UPGRADE_SCOPE}" = "MINOR" ]; then
            log_aurora_cluster_context "INFO" "UPGRADE_SCOPE = ${UPGRADE_SCOPE}" "upgrade" "MinorUpgrade"
            log_aurora_cluster_context "INFO" "Executing minor version upgrade tasks" "upgrade" "MinorUpgrade"
            
            # Step 1: Take manual snapshot FIRST for minor upgrades (if not done in PREUPGRADE)
            log_aurora_cluster_context "INFO" "Taking manual snapshot for minor upgrade (before upgrade)" "upgrade" "MinorUpgrade"
            cluster_snapshot
            
            # Step 2: Use existing parameter groups for minor upgrades - NO new parameter groups created
            cluster_param_group_name="${current_cluster_param_group}"
            instance_param_group_name="${current_instance_param_group}"
            
            echo "INFO: Minor upgrade - using existing cluster parameter group: ${cluster_param_group_name}"
            echo "INFO: Minor upgrade - using existing instance parameter group: ${instance_param_group_name}"
            
            # Validate parameter group assignment for minor upgrade
            echo -e "\nINFO: Validating parameter group assignment for minor upgrade...\n"
            determine_parameter_group_assignment "minor" "false"
        fi

        # Handle MAJOR version upgrades
        if [ "${UPGRADE_SCOPE}" = "MAJOR" ]; then
            log_aurora_cluster_context "INFO" "UPGRADE_SCOPE = ${UPGRADE_SCOPE}" "upgrade" "MajorUpgrade"
            log_aurora_cluster_context "INFO" "Executing major version upgrade tasks" "upgrade" "MajorUpgrade"

            # Step 1: NO manual snapshot for major upgrades during UPGRADE phase (Aurora creates automatic snapshot)
            log_aurora_cluster_context "INFO" "Skipping manual snapshot for major upgrade during UPGRADE phase (Aurora creates automatic snapshot)" "upgrade" "MajorUpgrade"

            # Step 2: Create NEW parameter groups for major upgrades (if not already created in PREUPGRADE phase)
            create_cluster_param_group
            create_instance_param_group
            
            # Validate parameter group assignment for major upgrade
            echo -e "\nINFO: Validating parameter group assignment for major upgrade...\n"
            determine_parameter_group_assignment "major" "false"

            # Step 3: Handle replication slots for major upgrades
            run_psql_drop_repl_slot
        fi

        ## below are common tasks that apply to major/minor version upgrade ##
        
        # call function to add Aurora cluster logs to CloudWatch if not already #
        log_aurora_operation_start "cloudwatch_logging" "Configuring CloudWatch log exports for Aurora cluster"
        cluster_modify_logs
        log_config_status=$?
        if [ "${log_config_status}" -eq 0 ]; then
            log_aurora_operation_complete "cloudwatch_logging" "success" "CloudWatch logging configured successfully"
            create_aurora_log_entry "cloudwatch_logging" "success" "Aurora cluster CloudWatch logging enabled"
        else
            log_aurora_operation_complete "cloudwatch_logging" "warning" "CloudWatch logging configuration had issues but upgrade can continue"
            create_aurora_log_entry "cloudwatch_logging" "warning" "Aurora cluster CloudWatch logging partially configured"
        fi

        # run pending-maintenance task on Aurora cluster instances and also Aurora cluster upgrade #
        cluster_pending_maint

        # call function to run Aurora cluster upgrade #
        cluster_upgrade

        # call function to update PostgreSQL extensions on Aurora cluster
        update_extensions
    
        # call function to run ANALYZE on Aurora cluster writer endpoint #
        run_psql_command_aurora "ANALYZE"

    fi

else # current_engine_type != aurora-postgresql
   
    log_aurora_error "Invalid Aurora Cluster-ID or Aurora Engine is NOT PostgreSQL. Please check Aurora Cluster-ID." "1" "engine_validation" "Verify that the cluster is an Aurora PostgreSQL cluster" "engine_validation"

fi
##-------------------------------------------------------------------------------------

# copy logs to s3 #
# Note: Aurora internal PostgreSQL database upgrade log file will be available in the Aurora CloudWatch log group.
copy_logs_to_s3

# Email notification is now handled by exit trap with SUCCESS/FAILED status
# send_email - removed (now handled by exit trap)
echo ""
echo -e "END -  ${EMAIL_SUBJECT} - $(date)\n"
log_aurora_cluster_context "INFO" "Aurora PostgreSQL upgrade workflow completed successfully: ${EMAIL_SUBJECT}" "workflow_complete"
create_aurora_log_entry "workflow_complete" "success" "Aurora PostgreSQL upgrade workflow completed" "{\"email_subject\":\"${EMAIL_SUBJECT}\"}"

# Generate comprehensive session summary
generate_aurora_session_summary "success" "Aurora PostgreSQL upgrade workflow completed successfully. All operations executed without errors."

exit 0
