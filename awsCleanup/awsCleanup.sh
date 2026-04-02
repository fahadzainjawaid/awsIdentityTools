#!/usr/bin/env bash
# =============================================================================
# AWS Account Full Cleanup Script
# Regions: ca-central-1, us-east-1
# Scope:  All regional resources + IAM users (global) + Lightsail
# WARNING: This is IRREVERSIBLE. Only run against a sandbox account.
# =============================================================================
set -euo pipefail

# =============================================================================
# countdown: display a 10-second abort window before each deletion
# Usage: countdown "<resource description>"
# =============================================================================
countdown() {
  local msg="$1"
  echo ""
  for i in $(seq 10 -1 1); do
    printf "\r  --> Deleting: %-55s | Press CTRL+C to abort | %2d sec " "$msg" "$i"
    sleep 1
  done
  printf "\r  --> Deleting: %-55s | proceeding...               \n" "$msg"
}

REGIONS=("ca-central-1" "us-east-1")

echo "============================================================"
echo " AWS ACCOUNT FULL CLEANUP"
echo " Account: $(aws sts get-caller-identity --query Account --output text)"
echo " Regions: ${REGIONS[*]}"
echo "============================================================"
echo ""
read -rp "Type 'DELETE EVERYTHING' to confirm and proceed: " CONFIRM
if [[ "$CONFIRM" != "DELETE EVERYTHING" ]]; then
  echo "Aborted."
  exit 1
fi

# =============================================================================
# Helper: delete resources in each region
# =============================================================================
for REGION in "${REGIONS[@]}"; do
  echo ""
  echo "============================================================"
  echo " Processing region: $REGION"
  echo "============================================================"

  # ---------------------------------------------------------------------------
  # 1. CloudFormation stacks (let CF delete its own managed resources first)
  # ---------------------------------------------------------------------------
  echo "[CFN] Deleting CloudFormation stacks in $REGION..."
  STACKS=$(aws cloudformation list-stacks \
    --region "$REGION" \
    --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE \
                          UPDATE_ROLLBACK_COMPLETE IMPORT_COMPLETE \
    --query "StackSummaries[?ParentId==null].StackName" \
    --output text 2>/dev/null || true)
  for STACK in $STACKS; do
    countdown "CloudFormation stack: $STACK"
    aws cloudformation delete-stack --region "$REGION" --stack-name "$STACK" || true
  done
  # Wait for stack deletions
  for STACK in $STACKS; do
    echo "  Waiting for stack deletion: $STACK"
    aws cloudformation wait stack-delete-complete --region "$REGION" --stack-name "$STACK" || true
  done

  # ---------------------------------------------------------------------------
  # 2. ECS – services and clusters
  # ---------------------------------------------------------------------------
  echo "[ECS] Deleting ECS services and clusters in $REGION..."
  CLUSTERS=$(aws ecs list-clusters --region "$REGION" --query "clusterArns[]" --output text 2>/dev/null || true)
  for CLUSTER in $CLUSTERS; do
    SERVICES=$(aws ecs list-services --region "$REGION" --cluster "$CLUSTER" \
      --query "serviceArns[]" --output text 2>/dev/null || true)
    for SVC in $SERVICES; do
      countdown "ECS service: $SVC"
      aws ecs update-service --region "$REGION" --cluster "$CLUSTER" --service "$SVC" --desired-count 0 >/dev/null || true
      aws ecs delete-service  --region "$REGION" --cluster "$CLUSTER" --service "$SVC" --force >/dev/null || true
    done
    countdown "ECS cluster: $CLUSTER"
    aws ecs delete-cluster --region "$REGION" --cluster "$CLUSTER" >/dev/null || true
  done

  # ---------------------------------------------------------------------------
  # 3. EKS – node groups and clusters
  # ---------------------------------------------------------------------------
  echo "[EKS] Deleting EKS clusters in $REGION..."
  EKS_CLUSTERS=$(aws eks list-clusters --region "$REGION" --query "clusters[]" --output text 2>/dev/null || true)
  for CLUSTER in $EKS_CLUSTERS; do
    NODEGROUPS=$(aws eks list-nodegroups --region "$REGION" --cluster-name "$CLUSTER" \
      --query "nodegroups[]" --output text 2>/dev/null || true)
    for NG in $NODEGROUPS; do
      countdown "EKS nodegroup: $NG"
      aws eks delete-nodegroup --region "$REGION" --cluster-name "$CLUSTER" --nodegroup-name "$NG" >/dev/null || true
      aws eks wait nodegroup-deleted --region "$REGION" --cluster-name "$CLUSTER" --nodegroup-name "$NG" || true
    done
    countdown "EKS cluster: $CLUSTER"
    aws eks delete-cluster --region "$REGION" --cluster-name "$CLUSTER" >/dev/null || true
    aws eks wait cluster-deleted --region "$REGION" --name "$CLUSTER" || true
  done

  # ---------------------------------------------------------------------------
  # 4. EC2 – instances
  # ---------------------------------------------------------------------------
  echo "[EC2] Terminating EC2 instances in $REGION..."
  INSTANCE_IDS=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=instance-state-name,Values=running,stopped,pending,stopping" \
    --query "Reservations[].Instances[].InstanceId" --output text 2>/dev/null || true)
  if [[ -n "$INSTANCE_IDS" ]]; then
    countdown "EC2 instances: $INSTANCE_IDS"
    aws ec2 terminate-instances --region "$REGION" --instance-ids $INSTANCE_IDS >/dev/null || true
    aws ec2 wait instance-terminated --region "$REGION" --instance-ids $INSTANCE_IDS || true
  fi

  # ---------------------------------------------------------------------------
  # 5. Auto Scaling Groups
  # ---------------------------------------------------------------------------
  echo "[ASG] Deleting Auto Scaling Groups in $REGION..."
  ASGS=$(aws autoscaling describe-auto-scaling-groups --region "$REGION" \
    --query "AutoScalingGroups[].AutoScalingGroupName" --output text 2>/dev/null || true)
  for ASG in $ASGS; do
    countdown "Auto Scaling Group: $ASG"
    aws autoscaling delete-auto-scaling-group --region "$REGION" \
      --auto-scaling-group-name "$ASG" --force-delete >/dev/null || true
  done

  # ---------------------------------------------------------------------------
  # 6. Load Balancers (ALB / NLB / Gateway LBs)
  # ---------------------------------------------------------------------------
  echo "[ELB] Deleting Elastic Load Balancers (v2) in $REGION..."
  LB_ARNS=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[].LoadBalancerArn" --output text 2>/dev/null || true)
  for LB in $LB_ARNS; do
    countdown "Load Balancer: $LB"
    aws elbv2 delete-load-balancer --region "$REGION" --load-balancer-arn "$LB" || true
  done

  echo "[ELB] Deleting Classic ELBs in $REGION..."
  CLASSIC_LBS=$(aws elb describe-load-balancers --region "$REGION" \
    --query "LoadBalancerDescriptions[].LoadBalancerName" --output text 2>/dev/null || true)
  for LB in $CLASSIC_LBS; do
    countdown "Classic ELB: $LB"
    aws elb delete-load-balancer --region "$REGION" --load-balancer-name "$LB" || true
  done

  # ---------------------------------------------------------------------------
  # 7. RDS – instances and clusters  (Multi-AZ / Aurora)
  # ---------------------------------------------------------------------------
  echo "[RDS] Deleting RDS instances and clusters in $REGION..."
  RDS_INSTANCES=$(aws rds describe-db-instances --region "$REGION" \
    --query "DBInstances[].DBInstanceIdentifier" --output text 2>/dev/null || true)
  for DB in $RDS_INSTANCES; do
    countdown "RDS instance: $DB"
    aws rds delete-db-instance --region "$REGION" \
      --db-instance-identifier "$DB" \
      --skip-final-snapshot \
      --delete-automated-backups >/dev/null || true
  done

  RDS_CLUSTERS=$(aws rds describe-db-clusters --region "$REGION" \
    --query "DBClusters[].DBClusterIdentifier" --output text 2>/dev/null || true)
  for CLUSTER in $RDS_CLUSTERS; do
    countdown "RDS cluster: $CLUSTER"
    aws rds delete-db-cluster --region "$REGION" \
      --db-cluster-identifier "$CLUSTER" \
      --skip-final-snapshot >/dev/null || true
  done

  # Wait for RDS deletions before proceeding
  for DB in $RDS_INSTANCES; do
    aws rds wait db-instance-deleted --region "$REGION" \
      --db-instance-identifier "$DB" 2>/dev/null || true
  done

  # ---------------------------------------------------------------------------
  # 8. ElastiCache clusters and replication groups
  # ---------------------------------------------------------------------------
  echo "[ElastiCache] Deleting ElastiCache resources in $REGION..."
  REPLICATION_GROUPS=$(aws elasticache describe-replication-groups --region "$REGION" \
    --query "ReplicationGroups[].ReplicationGroupId" --output text 2>/dev/null || true)
  for RG in $REPLICATION_GROUPS; do
    countdown "ElastiCache replication group: $RG"
    aws elasticache delete-replication-group --region "$REGION" \
      --replication-group-id "$RG" --retain-primary-cluster false >/dev/null || true
  done

  CACHE_CLUSTERS=$(aws elasticache describe-cache-clusters --region "$REGION" \
    --query "CacheClusters[].CacheClusterId" --output text 2>/dev/null || true)
  for CC in $CACHE_CLUSTERS; do
    countdown "ElastiCache cluster: $CC"
    aws elasticache delete-cache-cluster --region "$REGION" \
      --cache-cluster-id "$CC" >/dev/null || true
  done

  # ---------------------------------------------------------------------------
  # 9. Lambda functions
  # ---------------------------------------------------------------------------
  echo "[Lambda] Deleting Lambda functions in $REGION..."
  FUNCTIONS=$(aws lambda list-functions --region "$REGION" \
    --query "Functions[].FunctionName" --output text 2>/dev/null || true)
  for FN in $FUNCTIONS; do
    countdown "Lambda function: $FN"
    aws lambda delete-function --region "$REGION" --function-name "$FN" || true
  done

  # ---------------------------------------------------------------------------
  # 10. DynamoDB tables
  # ---------------------------------------------------------------------------
  echo "[DynamoDB] Deleting DynamoDB tables in $REGION..."
  TABLES=$(aws dynamodb list-tables --region "$REGION" \
    --query "TableNames[]" --output text 2>/dev/null || true)
  for TABLE in $TABLES; do
    countdown "DynamoDB table: $TABLE"
    aws dynamodb delete-table --region "$REGION" --table-name "$TABLE" >/dev/null || true
  done

  # ---------------------------------------------------------------------------
  # 11. SQS queues
  # ---------------------------------------------------------------------------
  echo "[SQS] Deleting SQS queues in $REGION..."
  QUEUES=$(aws sqs list-queues --region "$REGION" \
    --query "QueueUrls[]" --output text 2>/dev/null || true)
  for Q in $QUEUES; do
    countdown "SQS queue: $Q"
    aws sqs delete-queue --region "$REGION" --queue-url "$Q" || true
  done

  # ---------------------------------------------------------------------------
  # 12. SNS topics
  # ---------------------------------------------------------------------------
  echo "[SNS] Deleting SNS topics in $REGION..."
  TOPICS=$(aws sns list-topics --region "$REGION" \
    --query "Topics[].TopicArn" --output text 2>/dev/null || true)
  for TOPIC in $TOPICS; do
    countdown "SNS topic: $TOPIC"
    aws sns delete-topic --region "$REGION" --topic-arn "$TOPIC" || true
  done

  # ---------------------------------------------------------------------------
  # 13. ECR repositories
  # ---------------------------------------------------------------------------
  echo "[ECR] Deleting ECR repositories in $REGION..."
  REPOS=$(aws ecr describe-repositories --region "$REGION" \
    --query "repositories[].repositoryName" --output text 2>/dev/null || true)
  for REPO in $REPOS; do
    countdown "ECR repository: $REPO"
    aws ecr delete-repository --region "$REGION" \
      --repository-name "$REPO" --force >/dev/null || true
  done

  # ---------------------------------------------------------------------------
  # 14. Secrets Manager secrets
  # ---------------------------------------------------------------------------
  echo "[Secrets] Deleting Secrets Manager secrets in $REGION..."
  SECRETS=$(aws secretsmanager list-secrets --region "$REGION" \
    --query "SecretList[].ARN" --output text 2>/dev/null || true)
  for SECRET in $SECRETS; do
    countdown "Secrets Manager secret: $SECRET"
    aws secretsmanager delete-secret --region "$REGION" \
      --secret-id "$SECRET" --force-delete-without-recovery >/dev/null || true
  done

  # ---------------------------------------------------------------------------
  # 15. SSM Parameters
  # ---------------------------------------------------------------------------
  echo "[SSM] Deleting SSM parameters in $REGION..."
  SSM_PARAMS=$(aws ssm describe-parameters --region "$REGION" \
    --query "Parameters[].Name" --output text 2>/dev/null || true)
  for PARAM in $SSM_PARAMS; do
    countdown "SSM parameter: $PARAM"
    aws ssm delete-parameter --region "$REGION" --name "$PARAM" || true
  done

  # ---------------------------------------------------------------------------
  # 16. CloudWatch Log Groups
  # ---------------------------------------------------------------------------
  echo "[CWLogs] Deleting CloudWatch Log Groups in $REGION..."
  LOG_GROUPS=$(aws logs describe-log-groups --region "$REGION" \
    --query "logGroups[].logGroupName" --output text 2>/dev/null || true)
  for LG in $LOG_GROUPS; do
    countdown "CloudWatch Log Group: $LG"
    aws logs delete-log-group --region "$REGION" --log-group-name "$LG" || true
  done

  # ---------------------------------------------------------------------------
  # 17. S3 Buckets located in this region
  # ---------------------------------------------------------------------------
  echo "[S3] Deleting S3 buckets in region $REGION..."
  ALL_BUCKETS=$(aws s3api list-buckets --query "Buckets[].Name" --output text 2>/dev/null || true)
  for BUCKET in $ALL_BUCKETS; do
    BUCKET_REGION=$(aws s3api get-bucket-location --bucket "$BUCKET" \
      --query "LocationConstraint" --output text 2>/dev/null || true)
    # us-east-1 returns "None" from get-bucket-location
    [[ "$BUCKET_REGION" == "None" ]] && BUCKET_REGION="us-east-1"
    if [[ "$BUCKET_REGION" == "$REGION" ]]; then
      countdown "S3 bucket: $BUCKET"
      # Remove all object versions and delete markers
      aws s3api delete-objects --bucket "$BUCKET" \
        --delete "$(aws s3api list-object-versions --bucket "$BUCKET" \
          --query '{Objects: Versions[].{Key:Key,VersionId:VersionId}}' \
          --output json 2>/dev/null)" >/dev/null 2>&1 || true
      aws s3api delete-objects --bucket "$BUCKET" \
        --delete "$(aws s3api list-object-versions --bucket "$BUCKET" \
          --query '{Objects: DeleteMarkers[].{Key:Key,VersionId:VersionId}}' \
          --output json 2>/dev/null)" >/dev/null 2>&1 || true
      # Force-remove all objects (handles non-versioned buckets)
      aws s3 rm "s3://$BUCKET" --recursive >/dev/null 2>&1 || true
      aws s3api delete-bucket --bucket "$BUCKET" --region "$REGION" || true
    fi
  done

  # ---------------------------------------------------------------------------
  # 18. NAT Gateways (must be deleted before VPC)
  # ---------------------------------------------------------------------------
  echo "[VPC] Deleting NAT Gateways in $REGION..."
  NAT_GWS=$(aws ec2 describe-nat-gateways --region "$REGION" \
    --filter "Name=state,Values=available" \
    --query "NatGateways[].NatGatewayId" --output text 2>/dev/null || true)
  for NAT in $NAT_GWS; do
    countdown "NAT Gateway: $NAT"
    aws ec2 delete-nat-gateway --region "$REGION" --nat-gateway-id "$NAT" >/dev/null || true
  done
  # Wait for NAT gateway deletion
  for NAT in $NAT_GWS; do
    aws ec2 wait nat-gateway-deleted --region "$REGION" \
      --filter "Name=nat-gateway-id,Values=$NAT" 2>/dev/null || true
  done

  # ---------------------------------------------------------------------------
  # 19. VPCs (subnets, IGWs, route tables, security groups, then VPC)
  # ---------------------------------------------------------------------------
  echo "[VPC] Deleting non-default VPCs in $REGION..."
  VPCS=$(aws ec2 describe-vpcs --region "$REGION" \
    --filters "Name=isDefault,Values=false" \
    --query "Vpcs[].VpcId" --output text 2>/dev/null || true)
  for VPC in $VPCS; do
    countdown "VPC (IGWs/subnets/routes/SGs): $VPC"

    # Internet Gateways
    IGWS=$(aws ec2 describe-internet-gateways --region "$REGION" \
      --filters "Name=attachment.vpc-id,Values=$VPC" \
      --query "InternetGateways[].InternetGatewayId" --output text 2>/dev/null || true)
    for IGW in $IGWS; do
      aws ec2 detach-internet-gateway --region "$REGION" --internet-gateway-id "$IGW" --vpc-id "$VPC" || true
      aws ec2 delete-internet-gateway --region "$REGION" --internet-gateway-id "$IGW" || true
    done

    # Subnets
    SUBNETS=$(aws ec2 describe-subnets --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC" \
      --query "Subnets[].SubnetId" --output text 2>/dev/null || true)
    for SUBNET in $SUBNETS; do
      aws ec2 delete-subnet --region "$REGION" --subnet-id "$SUBNET" || true
    done

    # Route tables (non-main)
    RTS=$(aws ec2 describe-route-tables --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC" \
      --query "RouteTables[?Associations[?Main==\`false\`] || Associations==\`[]\`].RouteTableId" \
      --output text 2>/dev/null || true)
    for RT in $RTS; do
      aws ec2 delete-route-table --region "$REGION" --route-table-id "$RT" || true
    done

    # Non-default Security Groups
    SGS=$(aws ec2 describe-security-groups --region "$REGION" \
      --filters "Name=vpc-id,Values=$VPC" \
      --query "SecurityGroups[?GroupName!='default'].GroupId" --output text 2>/dev/null || true)
    for SG in $SGS; do
      aws ec2 delete-security-group --region "$REGION" --group-id "$SG" || true
    done

    # VPC
    aws ec2 delete-vpc --region "$REGION" --vpc-id "$VPC" || true
    echo "  Deleted VPC: $VPC"
  done

  # ---------------------------------------------------------------------------
  # 20. Elastic IPs
  # ---------------------------------------------------------------------------
  echo "[EIP] Releasing Elastic IPs in $REGION..."
  EIPS=$(aws ec2 describe-addresses --region "$REGION" \
    --query "Addresses[].AllocationId" --output text 2>/dev/null || true)
  for EIP in $EIPS; do
    countdown "Elastic IP: $EIP"
    aws ec2 release-address --region "$REGION" --allocation-id "$EIP" || true
  done

  # ---------------------------------------------------------------------------
  # 21. Lightsail – containers, databases, and instances
  # ---------------------------------------------------------------------------
  echo "[Lightsail] Deleting Lightsail resources in $REGION..."

  # Container services
  LS_CONTAINERS=$(aws lightsail get-container-services --region "$REGION" \
    --query "containerServices[].containerServiceName" --output text 2>/dev/null || true)
  for CS in $LS_CONTAINERS; do
    countdown "Lightsail container service: $CS"
    aws lightsail delete-container-service --region "$REGION" \
      --service-name "$CS" >/dev/null || true
  done

  # Relational databases
  LS_DBS=$(aws lightsail get-relational-databases --region "$REGION" \
    --query "relationalDatabases[].name" --output text 2>/dev/null || true)
  for DB in $LS_DBS; do
    countdown "Lightsail database: $DB"
    aws lightsail delete-relational-database --region "$REGION" \
      --relational-database-name "$DB" \
      --skip-final-snapshot >/dev/null || true
  done

  # Lightsail instances
  LS_INSTANCES=$(aws lightsail get-instances --region "$REGION" \
    --query "instances[].name" --output text 2>/dev/null || true)
  for INST in $LS_INSTANCES; do
    countdown "Lightsail instance: $INST"
    aws lightsail delete-instance --region "$REGION" \
      --instance-name "$INST" >/dev/null || true
  done

  echo "  Done with region: $REGION"
done

# =============================================================================
# Global: IAM Users (account-wide)
# =============================================================================
echo ""
echo "============================================================"
echo " Deleting IAM Users (GLOBAL – affects the whole account)"
echo "============================================================"
IAM_USERS=$(aws iam list-users --query "Users[].UserName" --output text 2>/dev/null || true)
for USER in $IAM_USERS; do
  echo "  Processing IAM user: $USER"

  # Detach managed policies
  ATTACHED=$(aws iam list-attached-user-policies --user-name "$USER" \
    --query "AttachedPolicies[].PolicyArn" --output text 2>/dev/null || true)
  for POLICY in $ATTACHED; do
    aws iam detach-user-policy --user-name "$USER" --policy-arn "$POLICY" || true
  done

  # Remove inline policies
  INLINE=$(aws iam list-user-policies --user-name "$USER" \
    --query "PolicyNames[]" --output text 2>/dev/null || true)
  for POLICY in $INLINE; do
    aws iam delete-user-policy --user-name "$USER" --policy-name "$POLICY" || true
  done

  # Remove from groups
  GROUPS=$(aws iam list-groups-for-user --user-name "$USER" \
    --query "Groups[].GroupName" --output text 2>/dev/null || true)
  for GROUP in $GROUPS; do
    aws iam remove-user-from-group --user-name "$USER" --group-name "$GROUP" || true
  done

  # Delete access keys
  KEYS=$(aws iam list-access-keys --user-name "$USER" \
    --query "AccessKeyMetadata[].AccessKeyId" --output text 2>/dev/null || true)
  for KEY in $KEYS; do
    aws iam delete-access-key --user-name "$USER" --access-key-id "$KEY" || true
  done

  # Delete MFA devices
  MFA_DEVICES=$(aws iam list-mfa-devices --user-name "$USER" \
    --query "MFADevices[].SerialNumber" --output text 2>/dev/null || true)
  for MFA in $MFA_DEVICES; do
    aws iam deactivate-mfa-device --user-name "$USER" --serial-number "$MFA" || true
    aws iam delete-virtual-mfa-device --serial-number "$MFA" || true
  done

  # Delete signing certificates
  CERTS=$(aws iam list-signing-certificates --user-name "$USER" \
    --query "Certificates[].CertificateId" --output text 2>/dev/null || true)
  for CERT in $CERTS; do
    aws iam delete-signing-certificate --user-name "$USER" --certificate-id "$CERT" || true
  done

  # Delete SSH public keys
  SSH_KEYS=$(aws iam list-ssh-public-keys --user-name "$USER" \
    --query "SSHPublicKeys[].SSHPublicKeyId" --output text 2>/dev/null || true)
  for SSH_KEY in $SSH_KEYS; do
    aws iam delete-ssh-public-key --user-name "$USER" --ssh-public-key-id "$SSH_KEY" || true
  done

  # Delete login profile (console password)
  aws iam delete-login-profile --user-name "$USER" 2>/dev/null || true

  # Delete the user
  countdown "IAM user: $USER"
  aws iam delete-user --user-name "$USER" || true
  echo "  Deleted IAM user: $USER"
done

echo ""
echo "============================================================"
echo " Cleanup complete."
echo "============================================================"
