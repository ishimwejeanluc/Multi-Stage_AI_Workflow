#!/bin/bash

################################################################################
# AWS EC2 Instance Deployment Script
# 
# Purpose: Deploy a production-ready EC2 instance with security groups, key pairs,
#          and tags based on a JSON infrastructure specification.
# 
# Usage: ./deploy_ec2.sh
# 
# Requirements: aws CLI v2, jq for JSON parsing, bash 4.0+
################################################################################

set -euo pipefail

# ============================================================================
# CONFIGURATION VARIABLES - Update these from your JSON spec
# ============================================================================

PROJECT_NAME="my-web-app"
AWS_REGION="us-east-1"
INSTANCE_TYPE="t2.micro"
AMI_ID="ami-0e86e20dae9224db8"
KEY_PAIR_NAME="my-web-app-keypair"
SECURITY_GROUP_NAME="my-web-app-sg"
SECURITY_GROUP_DESCRIPTION="Security group for my-web-app web server"

# Tags
TAG_ENVIRONMENT="Development"
TAG_OWNER="JeanLuc"

# File paths
KEY_FILE="${KEY_PAIR_NAME}.pem"
KEY_FILE_BACKUP="${KEY_PAIR_NAME}-backup-$(date +%s).pem"
STATE_FILE="/tmp/${PROJECT_NAME}-deploy-state.json"

# ============================================================================
# COLOR CODES FOR OUTPUT
# ============================================================================

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# ============================================================================
# LOGGING FUNCTIONS
# ============================================================================

log_info() {
    echo -e "${BLUE}[INFO]${NC} $*" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $*" >&2
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*" >&2
}

# ============================================================================
# ERROR HANDLING & CLEANUP
# ============================================================================

# Trap errors and cleanup
trap cleanup EXIT

cleanup() {
    local exit_code=$?
    
    if [[ $exit_code -ne 0 ]]; then
        log_error "Script failed with exit code $exit_code"
        log_info "Attempting rollback..."
        rollback_on_failure
    fi
    
    return $exit_code
}

rollback_on_failure() {
    log_warn "Rollback not implemented - manual cleanup may be required"
    log_warn "State file saved to: $STATE_FILE"
    log_warn "You may need to manually delete resources created during this run"
}

# ============================================================================
# VALIDATION FUNCTIONS
# ============================================================================

validate_prerequisites() {
    log_info "Validating prerequisites..."
    
    # Check AWS CLI
    if ! command -v aws &> /dev/null; then
        log_error "AWS CLI not found. Please install AWS CLI v2"
        return 1
    fi
    
    # Check jq for JSON parsing
    if ! command -v jq &> /dev/null; then
        log_warn "jq not found. Will use aws CLI for JSON parsing"
    fi
    
    # Check AWS credentials
    if ! aws sts get-caller-identity --region "$AWS_REGION" &> /dev/null; then
        log_error "AWS credentials not configured or invalid"
        log_error "Please configure AWS credentials using 'aws configure'"
        return 1
    fi
    
    # Diagnostic info
    local account_id
    account_id=$(aws sts get-caller-identity --query 'Account' --output text)
    log_info "AWS Account: $account_id"
    log_info "AWS Region: $AWS_REGION"
    
    log_success "All prerequisites validated"
}

validate_ami() {
    log_info "Validating AMI ID: $AMI_ID"
    
    if ! aws ec2 describe-images \
        --image-ids "$AMI_ID" \
        --region "$AWS_REGION" &> /dev/null; then
        log_error "AMI $AMI_ID not found in region $AWS_REGION"
        return 1
    fi
    
    log_success "AMI validated"
}

# ============================================================================
# KEY PAIR MANAGEMENT
# ============================================================================

create_or_skip_key_pair() {
    log_info "Checking key pair: $KEY_PAIR_NAME"
    
    # Check if key pair already exists in AWS
    if aws ec2 describe-key-pairs \
        --key-names "$KEY_PAIR_NAME" \
        --region "$AWS_REGION" &> /dev/null; then
        log_warn "Key pair '$KEY_PAIR_NAME' already exists in AWS"
        
        # Check if local file exists
        if [[ -f "$KEY_FILE" ]]; then
            log_warn "Local key file already exists: $KEY_FILE"
            log_info "Skipping key pair creation (already exists)"
            return 0
        else
            log_error "Key pair exists in AWS but local file not found at $KEY_FILE"
            log_error "Cannot retrieve private key from AWS. Please use existing key or delete and recreate"
            return 1
        fi
    fi
    
    # Create new key pair
    log_info "Creating new key pair: $KEY_PAIR_NAME"
    
    # Backup existing local key if present
    if [[ -f "$KEY_FILE" ]]; then
        log_warn "Backing up existing local key file to $KEY_FILE_BACKUP"
        mv "$KEY_FILE" "$KEY_FILE_BACKUP"
    fi
    
    # Create key pair
    aws ec2 create-key-pair \
        --key-name "$KEY_PAIR_NAME" \
        --region "$AWS_REGION" \
        --query 'KeyMaterial' \
        --output text > "$KEY_FILE"
    
    if [[ ! -f "$KEY_FILE" ]]; then
        log_error "Failed to create key pair"
        return 1
    fi
    
    # Set restrictive permissions
    chmod 400 "$KEY_FILE"
    
    log_success "Key pair created and saved to $KEY_FILE with permissions 400"
}

# ============================================================================
# SECURITY GROUP MANAGEMENT
# ============================================================================

create_or_skip_security_group() {
    log_info "Checking security group: $SECURITY_GROUP_NAME"
    
    # Get default VPC ID first
    local vpc_id
    vpc_id=$(aws ec2 describe-vpcs \
        --filters "Name=isDefault,Values=true" \
        --region "$AWS_REGION" \
        --query 'Vpcs[0].VpcId' \
        --output text 2>&1) || true
    
    if [[ -z "$vpc_id" || "$vpc_id" == "None" || "$vpc_id" == "null" ]]; then
        log_error "Could not determine default VPC in region $AWS_REGION"
        log_error "AWS Response: $vpc_id"
        return 1
    fi
    
    log_info "Using VPC: $vpc_id"
    
    # Check if security group already exists in this VPC
    local sg_id
    sg_id=$(aws ec2 describe-security-groups \
        --filters "Name=group-name,Values=$SECURITY_GROUP_NAME" "Name=vpc-id,Values=$vpc_id" \
        --region "$AWS_REGION" \
        --query 'SecurityGroups[0].GroupId' \
        --output text 2>&1 || echo "")
    
    # Handle AWS CLI errors
    if [[ "$sg_id" == *"InvalidGroup.NotFound"* ]] || [[ "$sg_id" == *"InvalidParameterValue"* ]]; then
        sg_id=""
    elif [[ "$sg_id" == "None" || "$sg_id" == "null" ]]; then
        sg_id=""
    fi
    
    if [[ -n "$sg_id" ]]; then
        log_warn "Security group '$SECURITY_GROUP_NAME' already exists with ID: $sg_id"
        echo "$sg_id"
        return 0
    fi
    
    # Create security group
    log_info "Creating security group: $SECURITY_GROUP_NAME in VPC: $vpc_id"
    sg_id=$(aws ec2 create-security-group \
        --group-name "$SECURITY_GROUP_NAME" \
        --description "$SECURITY_GROUP_DESCRIPTION" \
        --vpc-id "$vpc_id" \
        --region "$AWS_REGION" \
        --query 'GroupId' \
        --output text 2>&1)
    
    if [[ -z "$sg_id" || "$sg_id" == "None" || "$sg_id" == "null" ]]; then
        log_error "Failed to create security group. AWS Response: $sg_id"
        return 1
    fi
    
    log_success "Security group created with ID: $sg_id"
    
    # Add inbound rules
    add_security_group_rules "$sg_id"
    
    # Verify sg_id before returning
    if [[ -z "$sg_id" ]]; then
        log_error "Security group ID is empty after creation"
        return 1
    fi
    
    echo "$sg_id"
    return 0
}

add_security_group_rules() {
    local sg_id=$1
    
    log_info "Adding inbound rules to security group: $sg_id"
    
    # SSH Rule
    local ssh_result
    ssh_result=$(aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 22 \
        --cidr 0.0.0.0/0 \
        --region "$AWS_REGION" 2>&1 || true)
    
    if [[ "$ssh_result" == *"InvalidGroup.NotFound"* ]]; then
        log_error "Security group $sg_id not found when adding SSH rule"
        return 1
    elif [[ "$ssh_result" == *"error"* ]] || [[ "$ssh_result" == *"Error"* ]]; then
        if [[ "$ssh_result" == *"already exists"* ]]; then
            log_warn "SSH rule already exists"
        else
            log_warn "Could not add SSH rule: $ssh_result"
        fi
    else
        log_success "SSH rule added"
    fi
    
    # HTTP Rule
    local http_result
    http_result=$(aws ec2 authorize-security-group-ingress \
        --group-id "$sg_id" \
        --protocol tcp \
        --port 80 \
        --cidr 0.0.0.0/0 \
        --region "$AWS_REGION" 2>&1 || true)
    
    if [[ "$http_result" == *"InvalidGroup.NotFound"* ]]; then
        log_error "Security group $sg_id not found when adding HTTP rule"
        return 1
    elif [[ "$http_result" == *"error"* ]] || [[ "$http_result" == *"Error"* ]]; then
        if [[ "$http_result" == *"already exists"* ]]; then
            log_warn "HTTP rule already exists"
        else
            log_warn "Could not add HTTP rule: $http_result"
        fi
    else
        log_success "HTTP rule added"
    fi
    
    log_success "Security group rules configured"
    return 0
}

# ============================================================================
# EC2 INSTANCE LAUNCH
# ============================================================================

launch_ec2_instance() {
    local sg_id=$1
    
    log_info "Launching EC2 instance..."
    
    # Check if instance already exists
    local existing_instance
    existing_instance=$(aws ec2 describe-instances \
        --filters "Name=tag:Name,Values=$PROJECT_NAME" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].InstanceId' \
        --output text 2>/dev/null || echo "")
    
    if [[ -n "$existing_instance" && "$existing_instance" != "None" ]]; then
        log_warn "Instance already exists with ID: $existing_instance"
        echo "$existing_instance"
        return 0
    fi
    
    # Launch instance
    local instance_id
    instance_id=$(aws ec2 run-instances \
        --image-id "$AMI_ID" \
        --instance-type "$INSTANCE_TYPE" \
        --key-name "$KEY_PAIR_NAME" \
        --security-group-ids "$sg_id" \
        --region "$AWS_REGION" \
        --tag-specifications "ResourceType=instance,Tags=[{Key=Name,Value=$PROJECT_NAME},{Key=Environment,Value=$TAG_ENVIRONMENT},{Key=Owner,Value=$TAG_OWNER}]" \
        --query 'Instances[0].InstanceId' \
        --output text)
    
    if [[ -z "$instance_id" ]]; then
        log_error "Failed to launch EC2 instance"
        return 1
    fi
    
    log_success "EC2 instance launched with ID: $instance_id"
    echo "$instance_id"
}

# ============================================================================
# INSTANCE STATE MONITORING
# ============================================================================

wait_for_running_state() {
    local instance_id=$1
    local max_attempts=60
    local attempt=0
    
    log_info "Waiting for instance to reach 'running' state (max 5 minutes)..."
    
    while [[ $attempt -lt $max_attempts ]]; do
        local state
        state=$(aws ec2 describe-instances \
            --instance-ids "$instance_id" \
            --region "$AWS_REGION" \
            --query 'Reservations[0].Instances[0].State.Name' \
            --output text)
        
        if [[ "$state" == "running" ]]; then
            log_success "Instance is running"
            return 0
        elif [[ "$state" == "terminated" || "$state" == "terminating" ]]; then
            log_error "Instance entered terminal state: $state"
            return 1
        fi
        
        log_info "Current state: $state (attempt $((attempt + 1))/$max_attempts)"
        sleep 5
        ((attempt++))
    done
    
    log_error "Timeout waiting for instance to reach 'running' state"
    return 1
}

wait_for_status_checks() {
    local instance_id=$1
    local max_attempts=120
    local attempt=0
    
    log_info "Waiting for instance status checks to pass (max 10 minutes)..."
    
    while [[ $attempt -lt $max_attempts ]]; do
        local status_check
        status_check=$(aws ec2 describe-instance-status \
            --instance-ids "$instance_id" \
            --region "$AWS_REGION" \
            --query 'InstanceStatuses[0].InstanceStatus.Status' \
            --output text 2>/dev/null || echo "initializing")
        
        if [[ "$status_check" == "ok" ]]; then
            log_success "Instance status checks passed"
            return 0
        fi
        
        log_info "Status check status: $status_check (attempt $((attempt + 1))/$max_attempts)"
        sleep 5
        ((attempt++))
    done
    
    log_warn "Instance status checks did not complete in time, but proceeding"
}

# ============================================================================
# INSTANCE INFORMATION RETRIEVAL
# ============================================================================

get_public_ip() {
    local instance_id=$1
    
    local public_ip
    public_ip=$(aws ec2 describe-instances \
        --instance-ids "$instance_id" \
        --region "$AWS_REGION" \
        --query 'Reservations[0].Instances[0].PublicIpAddress' \
        --output text)
    
    if [[ -z "$public_ip" || "$public_ip" == "None" ]]; then
        log_warn "Could not retrieve public IP yet"
        return 1
    fi
    
    echo "$public_ip"
}

# ============================================================================
# TAGGING
# ============================================================================

apply_tags() {
    local instance_id=$1
    
    log_info "Applying tags to instance..."
    
    aws ec2 create-tags \
        --resources "$instance_id" \
        --tags \
            "Key=Name,Value=$PROJECT_NAME" \
            "Key=Environment,Value=$TAG_ENVIRONMENT" \
            "Key=Owner,Value=$TAG_OWNER" \
            "Key=DeploymentDate,Value=$(date -u +'%Y-%m-%dT%H:%M:%SZ')" \
        --region "$AWS_REGION"
    
    log_success "Tags applied successfully"
}

# ============================================================================
# STATE PERSISTENCE
# ============================================================================

save_state() {
    local instance_id=$1
    local sg_id=$2
    local public_ip=$3
    
    cat > "$STATE_FILE" << EOF
{
  "project_name": "$PROJECT_NAME",
  "region": "$AWS_REGION",
  "instance_id": "$instance_id",
  "security_group_id": "$sg_id",
  "public_ip": "$public_ip",
  "key_file": "$KEY_FILE",
  "deployment_timestamp": "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
}
EOF
    
    log_info "Deployment state saved to: $STATE_FILE"
}

# ============================================================================
# OUTPUT FORMATTING
# ============================================================================

display_deployment_summary() {
    local instance_id=$1
    local sg_id=$2
    local public_ip=$3
    
    echo ""
    echo "================================================================================"
    echo -e "${GREEN}AWS EC2 Deployment Completed Successfully${NC}"
    echo "================================================================================"
    echo ""
    echo "Deployment Summary:"
    echo "  Project Name:         $PROJECT_NAME"
    echo "  Region:               $AWS_REGION"
    echo "  Instance ID:          $instance_id"
    echo "  Instance Type:        $INSTANCE_TYPE"
    echo "  Security Group:       $SECURITY_GROUP_NAME ($sg_id)"
    echo "  Key Pair:             $KEY_PAIR_NAME"
    echo "  Public IP:            $public_ip"
    echo ""
    echo "SSH Connection:"
    echo -e "  ${BLUE}ssh -i \"$KEY_FILE\" ec2-user@$public_ip${NC}"
    echo ""
    echo "Useful AWS CLI Commands:"
    echo "  View instance:        aws ec2 describe-instances --instance-ids $instance_id --region $AWS_REGION"
    echo "  Stop instance:        aws ec2 stop-instances --instance-ids $instance_id --region $AWS_REGION"
    echo "  Terminate instance:   aws ec2 terminate-instances --instance-ids $instance_id --region $AWS_REGION"
    echo ""
    echo "================================================================================"
    echo ""
}

# ============================================================================
# MAIN EXECUTION FLOW
# ============================================================================

main() {
    log_info "Starting EC2 deployment for project: $PROJECT_NAME"
    
    # Step 1: Validate prerequisites
    validate_prerequisites
    
    # Step 2: Validate AMI
    validate_ami
    
    # Step 3: Create or skip key pair
    create_or_skip_key_pair
    
    # Step 4: Create or skip security group
    log_info "Proceeding to create/verify security group..."
    local sg_id
    sg_id=$(create_or_skip_security_group) || {
        log_error "Failed to create or retrieve security group"
        return 1
    }
    
    if [[ -z "$sg_id" ]]; then
        log_error "Security group ID is empty. Cannot proceed."
        return 1
    fi
    
    log_success "Security group verified: $sg_id"
    
    # Step 5: Launch EC2 instance
    log_info "Proceeding to launch EC2 instance with security group: $sg_id"
    local instance_id
    instance_id=$(launch_ec2_instance "$sg_id") || {
        log_error "Failed to launch EC2 instance"
        return 1
    }
    
    if [[ -z "$instance_id" ]]; then
        log_error "Instance ID is empty. Cannot proceed."
        return 1
    fi
    
    log_success "Instance launched: $instance_id"
    
    # Step 6: Wait for running state
    wait_for_running_state "$instance_id"
    
    # Step 7: Wait for status checks (optional, non-blocking)
    wait_for_status_checks "$instance_id" || true
    
    # Step 8: Retrieve public IP
    local public_ip
    public_ip=$(get_public_ip "$instance_id")
    
    if [[ -z "$public_ip" ]]; then
        log_error "Could not retrieve public IP address"
        return 1
    fi
    
    # Step 9: Apply tags
    apply_tags "$instance_id"
    
    # Step 10: Save deployment state
    save_state "$instance_id" "$sg_id" "$public_ip"
    
    # Step 11: Display summary
    display_deployment_summary "$instance_id" "$sg_id" "$public_ip"
    
    log_success "Deployment complete!"
}

# ============================================================================
# SCRIPT ENTRY POINT
# ============================================================================

if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
    main "$@"
fi
