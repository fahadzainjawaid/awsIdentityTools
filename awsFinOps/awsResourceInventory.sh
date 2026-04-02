#!/usr/bin/env bash
# =============================================================================
# AWS Resource Inventory Script with Cost Estimates
# Loops through all AWS resources across all regions and generates a markdown
# report with resource details and estimated monthly costs.
#
# Usage:
#   ./awsResourceInventory.sh [output_file] [region1,region2,...]
#
# Examples:
#   ./awsResourceInventory.sh                          # All regions -> resources.md
#   ./awsResourceInventory.sh output.md                # All regions -> output.md
#   ./awsResourceInventory.sh output.md us-east-1      # Single region
#   ./awsResourceInventory.sh output.md us-east-1,us-west-2  # Multiple regions
# =============================================================================
set -euo pipefail

# Parse arguments
OUTPUT_FILE="${1:-resources.md}"
REGION_FILTER="${2:-}"
TOTAL_COST=0

# =============================================================================
# Pre-flight checks
# =============================================================================
echo "Checking prerequisites..."

# Check for required tools
for cmd in aws jq bc; do
  if ! command -v "$cmd" &>/dev/null; then
    echo "ERROR: Required command '$cmd' not found. Please install it first."
    exit 1
  fi
done

# Validate AWS credentials
echo "Validating AWS credentials..."
if ! aws sts get-caller-identity &>/dev/null; then
  echo "ERROR: AWS credentials are not configured or invalid."
  echo ""
  echo "Please configure AWS credentials using one of these methods:"
  echo "  1. Run 'aws configure' to set up credentials"
  echo "  2. Export AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY"
  echo "  3. Use AWS SSO: 'aws sso login --profile <profile>'"
  echo "  4. Set AWS_PROFILE environment variable"
  echo ""
  echo "You can also use the awsLogin tool in this repository."
  exit 1
fi

# Get regions to scan
if [[ -n "$REGION_FILTER" ]]; then
  # User specified regions (comma-separated)
  REGIONS=$(echo "$REGION_FILTER" | tr ',' ' ')
  echo "Using specified regions: $REGIONS"
else
  # Get all enabled regions for the account
  echo "Fetching list of available regions..."
  REGIONS=$(aws ec2 describe-regions --query "Regions[].RegionName" --output text 2>/dev/null)
  
  if [[ -z "$REGIONS" ]]; then
    echo "ERROR: Could not fetch AWS regions. Check your permissions."
    exit 1
  fi
fi

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ACCOUNT_ALIAS=$(aws iam list-account-aliases --query "AccountAliases[0]" --output text 2>/dev/null || echo "N/A")

REGION_COUNT=$(echo "$REGIONS" | wc -w)
echo "============================================================"
echo " AWS RESOURCE INVENTORY"
echo " Account: $ACCOUNT_ID ($ACCOUNT_ALIAS)"
echo " Regions: $REGION_COUNT region(s)"
echo " Output:  $OUTPUT_FILE"
echo "============================================================"

# Initialize the markdown file
cat > "$OUTPUT_FILE" << EOF
# AWS Resource Inventory

**Account ID:** $ACCOUNT_ID  
**Account Alias:** $ACCOUNT_ALIAS  
**Generated:** $(date -u +"%Y-%m-%d %H:%M:%S UTC")

---

EOF

# =============================================================================
# Helper function: Add cost to total (handles empty/non-numeric values)
# =============================================================================
add_cost() {
  local cost="$1"
  if [[ -n "$cost" && "$cost" != "null" && "$cost" =~ ^[0-9.]+$ ]]; then
    TOTAL_COST=$(echo "$TOTAL_COST + $cost" | bc)
  fi
}

# =============================================================================
# Helper function: Get EC2 instance estimated monthly cost
# Based on instance type and region (simplified pricing)
# =============================================================================
get_ec2_cost() {
  local instance_type="$1"
  local region="$2"
  
  # Simplified pricing estimates (USD/month, assuming on-demand, 730 hrs/month)
  # These are approximate values - actual costs vary by region
  case "$instance_type" in
    t2.micro|t3.micro)     echo "8.50";;
    t2.small|t3.small)     echo "17.00";;
    t2.medium|t3.medium)   echo "34.00";;
    t2.large|t3.large)     echo "68.00";;
    t2.xlarge|t3.xlarge)   echo "136.00";;
    t2.2xlarge|t3.2xlarge) echo "272.00";;
    m5.large|m6i.large)    echo "70.00";;
    m5.xlarge|m6i.xlarge)  echo "140.00";;
    m5.2xlarge|m6i.2xlarge) echo "280.00";;
    m5.4xlarge|m6i.4xlarge) echo "560.00";;
    c5.large|c6i.large)    echo "62.00";;
    c5.xlarge|c6i.xlarge)  echo "124.00";;
    c5.2xlarge|c6i.2xlarge) echo "248.00";;
    r5.large|r6i.large)    echo "91.00";;
    r5.xlarge|r6i.xlarge)  echo "182.00";;
    *)                      echo "50.00";;  # Default estimate
  esac
}

# =============================================================================
# Helper function: Get RDS instance estimated monthly cost
# =============================================================================
get_rds_cost() {
  local instance_class="$1"
  local engine="$2"
  local multi_az="$3"
  
  local base_cost
  case "$instance_class" in
    db.t2.micro|db.t3.micro)     base_cost="15.00";;
    db.t2.small|db.t3.small)     base_cost="30.00";;
    db.t2.medium|db.t3.medium)   base_cost="60.00";;
    db.t2.large|db.t3.large)     base_cost="120.00";;
    db.m5.large|db.m6g.large)    base_cost="130.00";;
    db.m5.xlarge|db.m6g.xlarge)  base_cost="260.00";;
    db.r5.large|db.r6g.large)    base_cost="175.00";;
    db.r5.xlarge|db.r6g.xlarge)  base_cost="350.00";;
    *)                            base_cost="100.00";;
  esac
  
  # Multi-AZ doubles the cost
  if [[ "$multi_az" == "true" ]]; then
    base_cost=$(echo "$base_cost * 2" | bc)
  fi
  
  echo "$base_cost"
}

# =============================================================================
# Helper function: Get Lambda estimated monthly cost
# =============================================================================
get_lambda_cost() {
  local memory_mb="$1"
  local timeout="$2"
  
  # Estimate based on 1M invocations/month, average duration = timeout/4
  local avg_duration=$(echo "$timeout / 4" | bc)
  local gb_seconds=$(echo "1000000 * ($memory_mb / 1024) * ($avg_duration / 1000)" | bc 2>/dev/null || echo "0")
  local cost=$(echo "$gb_seconds * 0.0000166667" | bc 2>/dev/null || echo "1.00")
  
  # Minimum $1 estimate for any Lambda
  if (( $(echo "$cost < 1" | bc -l) )); then
    echo "1.00"
  else
    printf "%.2f" "$cost"
  fi
}

# =============================================================================
# Helper function: Get EBS volume estimated monthly cost
# =============================================================================
get_ebs_cost() {
  local volume_type="$1"
  local size_gb="$2"
  
  local price_per_gb
  case "$volume_type" in
    gp2)      price_per_gb="0.10";;
    gp3)      price_per_gb="0.08";;
    io1|io2)  price_per_gb="0.125";;
    st1)      price_per_gb="0.045";;
    sc1)      price_per_gb="0.025";;
    standard) price_per_gb="0.05";;
    *)        price_per_gb="0.10";;
  esac
  
  echo "$size_gb * $price_per_gb" | bc
}

# =============================================================================
# Helper function: Get NAT Gateway estimated monthly cost
# =============================================================================
get_nat_gateway_cost() {
  # NAT Gateway: ~$32/month base + data processing
  echo "45.00"
}

# =============================================================================
# Helper function: Get ELB estimated monthly cost
# =============================================================================
get_elb_cost() {
  local lb_type="$1"
  
  case "$lb_type" in
    application) echo "22.00";;
    network)     echo "22.00";;
    gateway)     echo "22.00";;
    classic)     echo "18.00";;
    *)           echo "22.00";;
  esac
}

# =============================================================================
# Helper function: Get ElastiCache estimated monthly cost
# =============================================================================
get_elasticache_cost() {
  local node_type="$1"
  
  case "$node_type" in
    cache.t2.micro|cache.t3.micro)   echo "12.00";;
    cache.t2.small|cache.t3.small)   echo "24.00";;
    cache.t2.medium|cache.t3.medium) echo "48.00";;
    cache.m5.large|cache.m6g.large)  echo "110.00";;
    cache.r5.large|cache.r6g.large)  echo "150.00";;
    *)                                echo "50.00";;
  esac
}

# =============================================================================
# Collect resources for each region
# =============================================================================
declare -A RESOURCE_DATA

for REGION in $REGIONS; do
  echo ""
  echo "Scanning region: $REGION..."
  
  REGION_RESOURCES=""
  REGION_COST=0
  
  # ---------------------------------------------------------------------------
  # EC2 Instances
  # ---------------------------------------------------------------------------
  echo "  [EC2] Checking instances..."
  EC2_DATA=$(aws ec2 describe-instances --region "$REGION" \
    --filters "Name=instance-state-name,Values=running,stopped,pending,stopping" \
    --query "Reservations[].Instances[].{Id:InstanceId,Type:InstanceType,State:State.Name,Name:Tags[?Key=='Name']|[0].Value}" \
    --output json 2>/dev/null || echo "[]")
  
  if [[ "$EC2_DATA" != "[]" ]]; then
    while IFS= read -r instance; do
      id=$(echo "$instance" | jq -r '.Id')
      type=$(echo "$instance" | jq -r '.Type')
      state=$(echo "$instance" | jq -r '.State')
      name=$(echo "$instance" | jq -r '.Name // "unnamed"')
      cost=$(get_ec2_cost "$type" "$REGION")
      
      # Stopped instances cost $0 for compute (but still pay for EBS)
      if [[ "$state" == "stopped" ]]; then
        cost="0.00"
      fi
      
      REGION_RESOURCES+="| EC2 Instance | \`$id\` | $name ($type, $state) | \$$cost |\n"
      add_cost "$cost"
      REGION_COST=$(echo "$REGION_COST + $cost" | bc)
    done < <(echo "$EC2_DATA" | jq -c '.[]')
  fi
  
  # ---------------------------------------------------------------------------
  # EBS Volumes
  # ---------------------------------------------------------------------------
  echo "  [EBS] Checking volumes..."
  EBS_DATA=$(aws ec2 describe-volumes --region "$REGION" \
    --query "Volumes[].{Id:VolumeId,Type:VolumeType,Size:Size,State:State,Name:Tags[?Key=='Name']|[0].Value}" \
    --output json 2>/dev/null || echo "[]")
  
  if [[ "$EBS_DATA" != "[]" ]]; then
    while IFS= read -r volume; do
      id=$(echo "$volume" | jq -r '.Id')
      type=$(echo "$volume" | jq -r '.Type')
      size=$(echo "$volume" | jq -r '.Size')
      state=$(echo "$volume" | jq -r '.State')
      name=$(echo "$volume" | jq -r '.Name // "unnamed"')
      cost=$(get_ebs_cost "$type" "$size")
      
      REGION_RESOURCES+="| EBS Volume | \`$id\` | $name (${size}GB $type, $state) | \$$cost |\n"
      add_cost "$cost"
      REGION_COST=$(echo "$REGION_COST + $cost" | bc)
    done < <(echo "$EBS_DATA" | jq -c '.[]')
  fi
  
  # ---------------------------------------------------------------------------
  # Elastic IPs
  # ---------------------------------------------------------------------------
  echo "  [EIP] Checking Elastic IPs..."
  EIP_DATA=$(aws ec2 describe-addresses --region "$REGION" \
    --query "Addresses[].{Ip:PublicIp,AllocationId:AllocationId,Associated:AssociationId}" \
    --output json 2>/dev/null || echo "[]")
  
  if [[ "$EIP_DATA" != "[]" ]]; then
    while IFS= read -r eip; do
      ip=$(echo "$eip" | jq -r '.Ip')
      alloc_id=$(echo "$eip" | jq -r '.AllocationId')
      associated=$(echo "$eip" | jq -r '.Associated')
      
      # Unassociated EIPs cost ~$3.65/month
      if [[ "$associated" == "null" ]]; then
        cost="3.65"
        status="unassociated"
      else
        cost="0.00"
        status="associated"
      fi
      
      REGION_RESOURCES+="| Elastic IP | \`$alloc_id\` | $ip ($status) | \$$cost |\n"
      add_cost "$cost"
      REGION_COST=$(echo "$REGION_COST + $cost" | bc)
    done < <(echo "$EIP_DATA" | jq -c '.[]')
  fi
  
  # ---------------------------------------------------------------------------
  # NAT Gateways
  # ---------------------------------------------------------------------------
  echo "  [NAT] Checking NAT Gateways..."
  NAT_DATA=$(aws ec2 describe-nat-gateways --region "$REGION" \
    --filter "Name=state,Values=available,pending" \
    --query "NatGateways[].{Id:NatGatewayId,State:State,VpcId:VpcId}" \
    --output json 2>/dev/null || echo "[]")
  
  if [[ "$NAT_DATA" != "[]" ]]; then
    while IFS= read -r nat; do
      id=$(echo "$nat" | jq -r '.Id')
      state=$(echo "$nat" | jq -r '.State')
      vpc=$(echo "$nat" | jq -r '.VpcId')
      cost=$(get_nat_gateway_cost)
      
      REGION_RESOURCES+="| NAT Gateway | \`$id\` | VPC: $vpc ($state) | \$$cost |\n"
      add_cost "$cost"
      REGION_COST=$(echo "$REGION_COST + $cost" | bc)
    done < <(echo "$NAT_DATA" | jq -c '.[]')
  fi
  
  # ---------------------------------------------------------------------------
  # Load Balancers (ALB/NLB/GLB)
  # ---------------------------------------------------------------------------
  echo "  [ELB] Checking Load Balancers..."
  LB_DATA=$(aws elbv2 describe-load-balancers --region "$REGION" \
    --query "LoadBalancers[].{Arn:LoadBalancerArn,Name:LoadBalancerName,Type:Type,State:State.Code}" \
    --output json 2>/dev/null || echo "[]")
  
  if [[ "$LB_DATA" != "[]" ]]; then
    while IFS= read -r lb; do
      name=$(echo "$lb" | jq -r '.Name')
      type=$(echo "$lb" | jq -r '.Type')
      state=$(echo "$lb" | jq -r '.State')
      cost=$(get_elb_cost "$type")
      
      REGION_RESOURCES+="| Load Balancer | \`$name\` | $type ($state) | \$$cost |\n"
      add_cost "$cost"
      REGION_COST=$(echo "$REGION_COST + $cost" | bc)
    done < <(echo "$LB_DATA" | jq -c '.[]')
  fi
  
  # Classic ELBs
  CLASSIC_LB_DATA=$(aws elb describe-load-balancers --region "$REGION" \
    --query "LoadBalancerDescriptions[].{Name:LoadBalancerName,VpcId:VPCId}" \
    --output json 2>/dev/null || echo "[]")
  
  if [[ "$CLASSIC_LB_DATA" != "[]" ]]; then
    while IFS= read -r lb; do
      name=$(echo "$lb" | jq -r '.Name')
      vpc=$(echo "$lb" | jq -r '.VpcId // "EC2-Classic"')
      cost=$(get_elb_cost "classic")
      
      REGION_RESOURCES+="| Classic ELB | \`$name\` | VPC: $vpc | \$$cost |\n"
      add_cost "$cost"
      REGION_COST=$(echo "$REGION_COST + $cost" | bc)
    done < <(echo "$CLASSIC_LB_DATA" | jq -c '.[]')
  fi
  
  # ---------------------------------------------------------------------------
  # RDS Instances
  # ---------------------------------------------------------------------------
  echo "  [RDS] Checking databases..."
  RDS_DATA=$(aws rds describe-db-instances --region "$REGION" \
    --query "DBInstances[].{Id:DBInstanceIdentifier,Class:DBInstanceClass,Engine:Engine,MultiAZ:MultiAZ,Status:DBInstanceStatus}" \
    --output json 2>/dev/null || echo "[]")
  
  if [[ "$RDS_DATA" != "[]" ]]; then
    while IFS= read -r db; do
      id=$(echo "$db" | jq -r '.Id')
      class=$(echo "$db" | jq -r '.Class')
      engine=$(echo "$db" | jq -r '.Engine')
      multi_az=$(echo "$db" | jq -r '.MultiAZ')
      status=$(echo "$db" | jq -r '.Status')
      cost=$(get_rds_cost "$class" "$engine" "$multi_az")
      
      az_label=""
      [[ "$multi_az" == "true" ]] && az_label=" Multi-AZ"
      
      REGION_RESOURCES+="| RDS Instance | \`$id\` | $engine $class$az_label ($status) | \$$cost |\n"
      add_cost "$cost"
      REGION_COST=$(echo "$REGION_COST + $cost" | bc)
    done < <(echo "$RDS_DATA" | jq -c '.[]')
  fi
  
  # ---------------------------------------------------------------------------
  # RDS Clusters (Aurora)
  # ---------------------------------------------------------------------------
  RDS_CLUSTER_DATA=$(aws rds describe-db-clusters --region "$REGION" \
    --query "DBClusters[].{Id:DBClusterIdentifier,Engine:Engine,Status:Status}" \
    --output json 2>/dev/null || echo "[]")
  
  if [[ "$RDS_CLUSTER_DATA" != "[]" ]]; then
    while IFS= read -r cluster; do
      id=$(echo "$cluster" | jq -r '.Id')
      engine=$(echo "$cluster" | jq -r '.Engine')
      status=$(echo "$cluster" | jq -r '.Status')
      cost="200.00"  # Aurora cluster base estimate
      
      REGION_RESOURCES+="| RDS Cluster | \`$id\` | $engine ($status) | \$$cost |\n"
      add_cost "$cost"
      REGION_COST=$(echo "$REGION_COST + $cost" | bc)
    done < <(echo "$RDS_CLUSTER_DATA" | jq -c '.[]')
  fi
  
  # ---------------------------------------------------------------------------
  # ElastiCache Clusters
  # ---------------------------------------------------------------------------
  echo "  [ElastiCache] Checking clusters..."
  CACHE_DATA=$(aws elasticache describe-cache-clusters --region "$REGION" \
    --query "CacheClusters[].{Id:CacheClusterId,NodeType:CacheNodeType,Engine:Engine,Status:CacheClusterStatus,NumNodes:NumCacheNodes}" \
    --output json 2>/dev/null || echo "[]")
  
  if [[ "$CACHE_DATA" != "[]" ]]; then
    while IFS= read -r cache; do
      id=$(echo "$cache" | jq -r '.Id')
      node_type=$(echo "$cache" | jq -r '.NodeType')
      engine=$(echo "$cache" | jq -r '.Engine')
      status=$(echo "$cache" | jq -r '.Status')
      num_nodes=$(echo "$cache" | jq -r '.NumNodes')
      node_cost=$(get_elasticache_cost "$node_type")
      cost=$(echo "$node_cost * $num_nodes" | bc)
      
      REGION_RESOURCES+="| ElastiCache | \`$id\` | $engine $node_type x$num_nodes ($status) | \$$cost |\n"
      add_cost "$cost"
      REGION_COST=$(echo "$REGION_COST + $cost" | bc)
    done < <(echo "$CACHE_DATA" | jq -c '.[]')
  fi
  
  # ---------------------------------------------------------------------------
  # Lambda Functions
  # ---------------------------------------------------------------------------
  echo "  [Lambda] Checking functions..."
  LAMBDA_DATA=$(aws lambda list-functions --region "$REGION" \
    --query "Functions[].{Name:FunctionName,Runtime:Runtime,Memory:MemorySize,Timeout:Timeout}" \
    --output json 2>/dev/null || echo "[]")
  
  if [[ "$LAMBDA_DATA" != "[]" ]]; then
    while IFS= read -r fn; do
      name=$(echo "$fn" | jq -r '.Name')
      runtime=$(echo "$fn" | jq -r '.Runtime // "N/A"')
      memory=$(echo "$fn" | jq -r '.Memory')
      timeout=$(echo "$fn" | jq -r '.Timeout')
      cost=$(get_lambda_cost "$memory" "$timeout")
      
      REGION_RESOURCES+="| Lambda | \`$name\` | $runtime (${memory}MB, ${timeout}s timeout) | \$$cost |\n"
      add_cost "$cost"
      REGION_COST=$(echo "$REGION_COST + $cost" | bc)
    done < <(echo "$LAMBDA_DATA" | jq -c '.[]')
  fi
  
  # ---------------------------------------------------------------------------
  # ECS Clusters and Services
  # ---------------------------------------------------------------------------
  echo "  [ECS] Checking clusters..."
  ECS_CLUSTERS=$(aws ecs list-clusters --region "$REGION" \
    --query "clusterArns[]" --output text 2>/dev/null || true)
  
  if [[ -n "$ECS_CLUSTERS" && "$ECS_CLUSTERS" != "None" ]]; then
  for cluster_arn in $ECS_CLUSTERS; do
    cluster_name=$(basename "$cluster_arn")
    
    # Get running services count
    services_count=$(aws ecs list-services --region "$REGION" --cluster "$cluster_arn" \
      --query "length(serviceArns)" --output text 2>/dev/null || echo "0")
    
    # Running tasks count
    tasks_count=$(aws ecs list-tasks --region "$REGION" --cluster "$cluster_arn" \
      --query "length(taskArns)" --output text 2>/dev/null || echo "0")
    
    # ECS itself is free; Fargate tasks have costs
    cost="0.00"
    if [[ "$tasks_count" -gt 0 ]]; then
      # Estimate $30/month per running task (Fargate avg)
      cost=$(echo "$tasks_count * 30" | bc)
    fi
    
    REGION_RESOURCES+="| ECS Cluster | \`$cluster_name\` | $services_count services, $tasks_count tasks | \$$cost |\n"
    add_cost "$cost"
    REGION_COST=$(echo "$REGION_COST + $cost" | bc)
  done
  fi
  
  # ---------------------------------------------------------------------------
  # EKS Clusters
  # ---------------------------------------------------------------------------
  echo "  [EKS] Checking clusters..."
  EKS_CLUSTERS=$(aws eks list-clusters --region "$REGION" \
    --query "clusters[]" --output text 2>/dev/null || true)
  
  if [[ -n "$EKS_CLUSTERS" && "$EKS_CLUSTERS" != "None" ]]; then
  for cluster in $EKS_CLUSTERS; do
    # EKS control plane: $0.10/hour = ~$73/month
    cost="73.00"
    
    # Add node groups
    nodegroups=$(aws eks list-nodegroups --region "$REGION" --cluster-name "$cluster" \
      --query "nodegroups[]" --output text 2>/dev/null || true)
    ng_count=$(echo "$nodegroups" | wc -w)
    
    REGION_RESOURCES+="| EKS Cluster | \`$cluster\` | $ng_count node groups | \$$cost |\n"
    add_cost "$cost"
    REGION_COST=$(echo "$REGION_COST + $cost" | bc)
  done
  fi
  
  # ---------------------------------------------------------------------------
  # DynamoDB Tables
  # ---------------------------------------------------------------------------
  echo "  [DynamoDB] Checking tables..."
  DDB_TABLES=$(aws dynamodb list-tables --region "$REGION" \
    --query "TableNames[]" --output text 2>/dev/null || true)
  
  if [[ -n "$DDB_TABLES" && "$DDB_TABLES" != "None" ]]; then
  for table in $DDB_TABLES; do
    # Get table details
    table_info=$(aws dynamodb describe-table --region "$REGION" --table-name "$table" \
      --query "Table.{Mode:BillingModeSummary.BillingMode,RCU:ProvisionedThroughput.ReadCapacityUnits,WCU:ProvisionedThroughput.WriteCapacityUnits,Size:TableSizeBytes}" \
      --output json 2>/dev/null || echo "{}")
    
    mode=$(echo "$table_info" | jq -r '.Mode // "PROVISIONED"')
    rcu=$(echo "$table_info" | jq -r '.RCU // 0')
    wcu=$(echo "$table_info" | jq -r '.WCU // 0')
    size_bytes=$(echo "$table_info" | jq -r '.Size // 0')
    size_gb=$(echo "scale=2; $size_bytes / 1073741824" | bc)
    
    if [[ "$mode" == "PAY_PER_REQUEST" ]]; then
      # On-demand: estimate based on table size
      cost=$(echo "scale=2; $size_gb * 0.25 + 1" | bc)
      mode_label="On-Demand"
    else
      # Provisioned: $0.00065 per WCU, $0.00013 per RCU (per hour)
      cost=$(echo "scale=2; ($wcu * 0.00065 + $rcu * 0.00013) * 730" | bc)
      mode_label="Provisioned (${rcu}R/${wcu}W)"
    fi
    
    REGION_RESOURCES+="| DynamoDB | \`$table\` | $mode_label (${size_gb}GB) | \$$cost |\n"
    add_cost "$cost"
    REGION_COST=$(echo "$REGION_COST + $cost" | bc)
  done
  fi
  
  # ---------------------------------------------------------------------------
  # SQS Queues
  # ---------------------------------------------------------------------------
  echo "  [SQS] Checking queues..."
  SQS_QUEUES=$(aws sqs list-queues --region "$REGION" \
    --query "QueueUrls[]" --output text 2>/dev/null || true)
  
  if [[ -n "$SQS_QUEUES" && "$SQS_QUEUES" != "None" ]]; then
    for queue_url in $SQS_QUEUES; do
      queue_name=$(basename "$queue_url")
      # SQS: First 1M requests free, then $0.40 per million
      cost="0.50"  # Estimate
      
      REGION_RESOURCES+="| SQS Queue | \`$queue_name\` | Standard queue | \$$cost |\n"
      add_cost "$cost"
      REGION_COST=$(echo "$REGION_COST + $cost" | bc)
    done
  fi
  
  # ---------------------------------------------------------------------------
  # SNS Topics
  # ---------------------------------------------------------------------------
  echo "  [SNS] Checking topics..."
  SNS_TOPICS=$(aws sns list-topics --region "$REGION" \
    --query "Topics[].TopicArn" --output text 2>/dev/null || true)
  
  if [[ -n "$SNS_TOPICS" && "$SNS_TOPICS" != "None" ]]; then
    for topic_arn in $SNS_TOPICS; do
      # Extract topic name from ARN (arn:aws:sns:region:account:topic-name)
      topic_name="${topic_arn##*:}"
      # SNS: First 1M requests free
      cost="0.50"  # Estimate
      
      REGION_RESOURCES+="| SNS Topic | \`$topic_name\` | Standard topic | \$$cost |\n"
      add_cost "$cost"
      REGION_COST=$(echo "$REGION_COST + $cost" | bc)
    done
  fi
  
  # ---------------------------------------------------------------------------
  # Secrets Manager
  # ---------------------------------------------------------------------------
  echo "  [Secrets] Checking secrets..."
  SECRETS=$(aws secretsmanager list-secrets --region "$REGION" \
    --query "SecretList[].{Name:Name,Arn:ARN}" --output json 2>/dev/null || echo "[]")
  
  if [[ "$SECRETS" != "[]" ]]; then
    while IFS= read -r secret; do
      name=$(echo "$secret" | jq -r '.Name')
      # Secrets Manager: $0.40/secret/month + $0.05 per 10K API calls
      cost="0.40"
      
      REGION_RESOURCES+="| Secret | \`$name\` | Secrets Manager | \$$cost |\n"
      add_cost "$cost"
      REGION_COST=$(echo "$REGION_COST + $cost" | bc)
    done < <(echo "$SECRETS" | jq -c '.[]')
  fi
  
  # ---------------------------------------------------------------------------
  # CloudWatch Log Groups (estimate storage cost)
  # ---------------------------------------------------------------------------
  echo "  [CloudWatch] Checking log groups..."
  LOG_GROUPS=$(aws logs describe-log-groups --region "$REGION" \
    --query "logGroups[].{Name:logGroupName,StoredBytes:storedBytes}" --output json 2>/dev/null || echo "[]")
  
  log_group_count=0
  total_log_storage=0
  if [[ "$LOG_GROUPS" != "[]" ]]; then
    while IFS= read -r lg; do
      stored=$(echo "$lg" | jq -r '.StoredBytes // 0')
      total_log_storage=$((total_log_storage + stored))
      log_group_count=$((log_group_count + 1))
    done < <(echo "$LOG_GROUPS" | jq -c '.[]')
    
    if [[ $log_group_count -gt 0 ]]; then
      storage_gb=$(echo "scale=2; $total_log_storage / 1073741824" | bc)
      # CloudWatch Logs: $0.03/GB stored
      cost=$(echo "scale=2; $storage_gb * 0.03" | bc)
      [[ $(echo "$cost < 0.01" | bc) -eq 1 ]] && cost="0.01"
      
      REGION_RESOURCES+="| CloudWatch Logs | $log_group_count groups | ${storage_gb}GB stored | \$$cost |\n"
      add_cost "$cost"
      REGION_COST=$(echo "$REGION_COST + $cost" | bc)
    fi
  fi
  
  # ---------------------------------------------------------------------------
  # VPCs (non-default)
  # ---------------------------------------------------------------------------
  echo "  [VPC] Checking VPCs..."
  VPC_DATA=$(aws ec2 describe-vpcs --region "$REGION" \
    --query "Vpcs[?IsDefault==\`false\`].{Id:VpcId,Cidr:CidrBlock,Name:Tags[?Key=='Name']|[0].Value}" \
    --output json 2>/dev/null || echo "[]")
  
  if [[ "$VPC_DATA" != "[]" ]]; then
    while IFS= read -r vpc; do
      id=$(echo "$vpc" | jq -r '.Id')
      cidr=$(echo "$vpc" | jq -r '.Cidr')
      name=$(echo "$vpc" | jq -r '.Name // "unnamed"')
      # VPCs are free, but we list them
      cost="0.00"
      
      REGION_RESOURCES+="| VPC | \`$id\` | $name ($cidr) | \$$cost |\n"
    done < <(echo "$VPC_DATA" | jq -c '.[]')
  fi
  
  # ---------------------------------------------------------------------------
  # ECR Repositories
  # ---------------------------------------------------------------------------
  echo "  [ECR] Checking repositories..."
  ECR_REPOS=$(aws ecr describe-repositories --region "$REGION" \
    --query "repositories[].{Name:repositoryName,Uri:repositoryUri}" --output json 2>/dev/null || echo "[]")
  
  if [[ "$ECR_REPOS" != "[]" ]]; then
    while IFS= read -r repo; do
      name=$(echo "$repo" | jq -r '.Name')
      # ECR: $0.10/GB/month for storage
      # Get image count
      image_count=$(aws ecr describe-images --region "$REGION" --repository-name "$name" \
        --query "length(imageDetails)" --output text 2>/dev/null || echo "0")
      cost=$(echo "scale=2; $image_count * 0.5" | bc 2>/dev/null || echo "0.50")
      [[ $(echo "$cost < 0.10" | bc) -eq 1 ]] && cost="0.10"
      
      REGION_RESOURCES+="| ECR Repo | \`$name\` | $image_count images | \$$cost |\n"
      add_cost "$cost"
      REGION_COST=$(echo "$REGION_COST + $cost" | bc)
    done < <(echo "$ECR_REPOS" | jq -c '.[]')
  fi
  
  # ---------------------------------------------------------------------------
  # API Gateways
  # ---------------------------------------------------------------------------
  echo "  [API Gateway] Checking APIs..."
  APIGW_REST=$(aws apigateway get-rest-apis --region "$REGION" \
    --query "items[].{Id:id,Name:name}" --output json 2>/dev/null || echo "[]")
  
  if [[ "$APIGW_REST" != "[]" ]]; then
    while IFS= read -r api; do
      id=$(echo "$api" | jq -r '.Id')
      name=$(echo "$api" | jq -r '.Name')
      # API Gateway: $3.50 per million requests
      cost="3.50"
      
      REGION_RESOURCES+="| API Gateway | \`$id\` | $name (REST) | \$$cost |\n"
      add_cost "$cost"
      REGION_COST=$(echo "$REGION_COST + $cost" | bc)
    done < <(echo "$APIGW_REST" | jq -c '.[]')
  fi
  
  # HTTP APIs
  APIGW_HTTP=$(aws apigatewayv2 get-apis --region "$REGION" \
    --query "Items[].{Id:ApiId,Name:Name,Protocol:ProtocolType}" --output json 2>/dev/null || echo "[]")
  
  if [[ "$APIGW_HTTP" != "[]" ]]; then
    while IFS= read -r api; do
      id=$(echo "$api" | jq -r '.Id')
      name=$(echo "$api" | jq -r '.Name')
      protocol=$(echo "$api" | jq -r '.Protocol')
      cost="1.00"
      
      REGION_RESOURCES+="| API Gateway | \`$id\` | $name ($protocol) | \$$cost |\n"
      add_cost "$cost"
      REGION_COST=$(echo "$REGION_COST + $cost" | bc)
    done < <(echo "$APIGW_HTTP" | jq -c '.[]')
  fi
  
  # ---------------------------------------------------------------------------
  # CloudFormation Stacks
  # ---------------------------------------------------------------------------
  echo "  [CloudFormation] Checking stacks..."
  CFN_STACKS=$(aws cloudformation list-stacks --region "$REGION" \
    --stack-status-filter CREATE_COMPLETE UPDATE_COMPLETE ROLLBACK_COMPLETE UPDATE_ROLLBACK_COMPLETE \
    --query "StackSummaries[].{Name:StackName,Status:StackStatus}" --output json 2>/dev/null || echo "[]")
  
  if [[ "$CFN_STACKS" != "[]" ]]; then
    while IFS= read -r stack; do
      name=$(echo "$stack" | jq -r '.Name')
      status=$(echo "$stack" | jq -r '.Status')
      # CloudFormation is free
      cost="0.00"
      
      REGION_RESOURCES+="| CFN Stack | \`$name\` | $status | \$$cost |\n"
    done < <(echo "$CFN_STACKS" | jq -c '.[]')
  fi
  
  # ---------------------------------------------------------------------------
  # Write region section to output file
  # ---------------------------------------------------------------------------
  if [[ -n "$REGION_RESOURCES" ]]; then
    {
      echo "## $REGION"
      echo ""
      echo "**Regional Cost Estimate:** \$$(printf "%.2f" "$REGION_COST")/month"
      echo ""
      echo "| Type | Identifier | Details | Est. Monthly Cost |"
      echo "|------|------------|---------|-------------------|"
      echo -e "$REGION_RESOURCES"
    } >> "$OUTPUT_FILE"
  fi
  
done

# =============================================================================
# Global Resources (S3, IAM, Route53, CloudFront)
# =============================================================================
echo ""
echo "Scanning global resources..."

GLOBAL_RESOURCES=""
GLOBAL_COST=0

# ---------------------------------------------------------------------------
# S3 Buckets
# ---------------------------------------------------------------------------
echo "  [S3] Checking buckets..."
S3_BUCKETS=$(aws s3api list-buckets --query "Buckets[].Name" --output text 2>/dev/null || true)

if [[ -n "$S3_BUCKETS" && "$S3_BUCKETS" != "None" ]]; then
for bucket in $S3_BUCKETS; do
  # Get bucket region
  bucket_region=$(aws s3api get-bucket-location --bucket "$bucket" \
    --query "LocationConstraint" --output text 2>/dev/null || echo "us-east-1")
  [[ "$bucket_region" == "None" || "$bucket_region" == "null" ]] && bucket_region="us-east-1"
  
  # Get bucket size (this can be slow for large buckets)
  size_bytes=$(aws s3api list-objects-v2 --bucket "$bucket" \
    --query "sum(Contents[].Size)" --output text 2>/dev/null || echo "0")
  [[ "$size_bytes" == "None" || "$size_bytes" == "null" ]] && size_bytes="0"
  
  size_gb=$(echo "scale=2; ${size_bytes:-0} / 1073741824" | bc)
  # S3 Standard: $0.023/GB/month
  cost=$(echo "scale=2; $size_gb * 0.023" | bc)
  [[ $(echo "$cost < 0.01" | bc) -eq 1 ]] && cost="0.01"
  
  GLOBAL_RESOURCES+="| S3 Bucket | \`$bucket\` | ${size_gb}GB ($bucket_region) | \$$cost |\n"
  add_cost "$cost"
  GLOBAL_COST=$(echo "$GLOBAL_COST + $cost" | bc)
done
fi

# ---------------------------------------------------------------------------
# IAM Users
# ---------------------------------------------------------------------------
echo "  [IAM] Checking users..."
IAM_USERS=$(aws iam list-users --query "Users[].{Name:UserName,Created:CreateDate}" --output json 2>/dev/null || echo "[]")

if [[ "$IAM_USERS" != "[]" ]]; then
  while IFS= read -r user; do
    name=$(echo "$user" | jq -r '.Name')
    created=$(echo "$user" | jq -r '.Created' | cut -d'T' -f1)
    # IAM is free
    cost="0.00"
    
    GLOBAL_RESOURCES+="| IAM User | \`$name\` | Created: $created | \$$cost |\n"
  done < <(echo "$IAM_USERS" | jq -c '.[]')
fi

# ---------------------------------------------------------------------------
# IAM Roles (non-AWS-managed)
# ---------------------------------------------------------------------------
echo "  [IAM] Checking roles..."
IAM_ROLES=$(aws iam list-roles \
  --query "Roles[?!starts_with(RoleName, 'AWS') && !starts_with(RoleName, 'aws-')].{Name:RoleName,Path:Path}" \
  --output json 2>/dev/null || echo "[]")

if [[ "$IAM_ROLES" != "[]" ]]; then
  role_count=$(echo "$IAM_ROLES" | jq 'length')
  # IAM is free
  GLOBAL_RESOURCES+="| IAM Roles | $role_count custom roles | User-created roles | \$0.00 |\n"
fi

# ---------------------------------------------------------------------------
# Route 53 Hosted Zones
# ---------------------------------------------------------------------------
echo "  [Route53] Checking hosted zones..."
R53_ZONES=$(aws route53 list-hosted-zones \
  --query "HostedZones[].{Id:Id,Name:Name,Private:Config.PrivateZone,RecordCount:ResourceRecordSetCount}" \
  --output json 2>/dev/null || echo "[]")

if [[ "$R53_ZONES" != "[]" ]]; then
  while IFS= read -r zone; do
    id=$(echo "$zone" | jq -r '.Id' | sed 's|/hostedzone/||')
    name=$(echo "$zone" | jq -r '.Name')
    private=$(echo "$zone" | jq -r '.Private')
    record_count=$(echo "$zone" | jq -r '.RecordCount')
    # Route 53: $0.50/hosted zone/month
    cost="0.50"
    
    zone_type="Public"
    [[ "$private" == "true" ]] && zone_type="Private"
    
    GLOBAL_RESOURCES+="| Route 53 | \`$name\` | $zone_type zone ($record_count records) | \$$cost |\n"
    add_cost "$cost"
    GLOBAL_COST=$(echo "$GLOBAL_COST + $cost" | bc)
  done < <(echo "$R53_ZONES" | jq -c '.[]')
fi

# ---------------------------------------------------------------------------
# CloudFront Distributions
# ---------------------------------------------------------------------------
echo "  [CloudFront] Checking distributions..."
CF_DISTROS=$(aws cloudfront list-distributions \
  --query "DistributionList.Items[].{Id:Id,Domain:DomainName,Status:Status,Enabled:Enabled}" \
  --output json 2>/dev/null || echo "[]")

if [[ "$CF_DISTROS" != "[]" && "$CF_DISTROS" != "null" ]]; then
  while IFS= read -r distro; do
    id=$(echo "$distro" | jq -r '.Id')
    domain=$(echo "$distro" | jq -r '.Domain')
    status=$(echo "$distro" | jq -r '.Status')
    enabled=$(echo "$distro" | jq -r '.Enabled')
    # CloudFront: varies widely, estimate $10/month base
    cost="10.00"
    
    GLOBAL_RESOURCES+="| CloudFront | \`$id\` | $domain ($status, enabled=$enabled) | \$$cost |\n"
    add_cost "$cost"
    GLOBAL_COST=$(echo "$GLOBAL_COST + $cost" | bc)
  done < <(echo "$CF_DISTROS" | jq -c '.[]')
fi

# ---------------------------------------------------------------------------
# ACM Certificates
# ---------------------------------------------------------------------------
echo "  [ACM] Checking certificates..."
# Check in us-east-1 for global certs (CloudFront)
ACM_CERTS=$(aws acm list-certificates --region us-east-1 \
  --query "CertificateSummaryList[].{Arn:CertificateArn,Domain:DomainName}" \
  --output json 2>/dev/null || echo "[]")

if [[ "$ACM_CERTS" != "[]" ]]; then
  cert_count=$(echo "$ACM_CERTS" | jq 'length')
  # ACM public certs are free
  GLOBAL_RESOURCES+="| ACM Certs | $cert_count certificates | Public SSL/TLS certs | \$0.00 |\n"
fi

# ---------------------------------------------------------------------------
# Write global section to output file
# ---------------------------------------------------------------------------
if [[ -n "$GLOBAL_RESOURCES" ]]; then
  {
    echo "## Global Resources"
    echo ""
    echo "**Global Cost Estimate:** \$$(printf "%.2f" "$GLOBAL_COST")/month"
    echo ""
    echo "| Type | Identifier | Details | Est. Monthly Cost |"
    echo "|------|------------|---------|-------------------|"
    echo -e "$GLOBAL_RESOURCES"
  } >> "$OUTPUT_FILE"
fi

# =============================================================================
# Summary
# =============================================================================
{
  echo ""
  echo "---"
  echo ""
  echo "## Cost Summary"
  echo ""
  echo "| Category | Estimated Monthly Cost |"
  echo "|----------|------------------------|"
  echo "| **Total** | **\$$(printf "%.2f" "$TOTAL_COST")** |"
  echo ""
  echo "> **Note:** These are estimated costs based on list prices and simplified assumptions."
  echo "> Actual costs may vary based on usage patterns, reserved instances, savings plans,"
  echo "> data transfer, and other factors. For accurate costs, check AWS Cost Explorer."
} >> "$OUTPUT_FILE"

echo ""
echo "============================================================"
echo " INVENTORY COMPLETE"
echo " Output: $OUTPUT_FILE"
echo " Estimated Monthly Cost: \$$(printf "%.2f" "$TOTAL_COST")"
echo "============================================================"
