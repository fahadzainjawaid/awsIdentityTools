# AWS Identity Tools

A comprehensive collection of CLI tools for managing AWS credentials, authentication, Azure DevOps OIDC integration, resource inventory, and account cleanup. This toolkit simplifies AWS SSO login, credential management, automated CI/CD workflows, FinOps reporting, and sandbox account maintenance.

## 🚀 Features

### Identity & Authentication
- **AWS SSO Authentication**: Streamlined login process using AWS Identity Center (SSO)
- **Profile Management**: Easy switching between AWS profiles
- **Azure DevOps OIDC Integration**: Automated setup and management of OIDC providers for Azure DevOps pipelines
- **Credential Backup**: Automatic backup of existing credentials before making changes
- **Multi-Account Support**: Work with multiple AWS accounts and roles
- **Interactive Setup**: User-friendly prompts for configuration
- **Trust Policy Management**: Dynamic trust policy generation for secure OIDC authentication

### FinOps & Resource Management
- **Resource Inventory**: Comprehensive multi-region resource scanning with cost estimates
- **Cost Reporting**: Markdown reports with estimated monthly costs per resource
- **Account Cleanup**: Automated deletion of AWS resources for sandbox account maintenance

## 📦 Installation

### Prerequisites

- Node.js (version 14 or higher)
- npm
- AWS CLI v2 installed and configured
- An AWS account with AWS Identity Center (SSO) configured (for SSO features)
- Azure DevOps organization (for OIDC integration features)
- `jq` and `bc` (for shell script tools)

### Installation

1. Clone this repository:
```bash
git clone <repository-url>
cd awsIdentityTools
```

2. Install dependencies:
```bash
npm install
```

3. Build the project:
```bash
npm run compile
```

4. Set up the CLI tools globally:
```bash
npm run setup
```

5. Make shell scripts executable:
```bash
chmod +x awsCleanup/awsCleanup.sh awsFinOps/awsResourceInventory.sh
```

## ⚙️ Configuration

### AWS Identity Center Setup (Interactive)

Run the setup wizard to configure your AWS Identity Center settings:

```bash
node cli/setup.mjs
```

The setup wizard will prompt you for:
- **Org name**: An identifier for this configuration (supports multiple orgs)
- **AWS Region**: Your Identity Center region (e.g., `us-east-1`)
- **SSO Start URL**: Your organization's AWS Identity Center URL
- **Allowed role names**: Optional filter for specific roles
- **Account IDs**: Optional filter for specific accounts

Configuration is saved to `~/.aws/awsIdentityConfig.json` (outside the repo, safe from version control).

**Multiple Organizations:**
```bash
# Configure multiple orgs
node cli/setup.mjs  # Follow prompts, enter org name "production"
node cli/setup.mjs  # Follow prompts, enter org name "development"

# Use specific org when logging in
awsLogin --org production
awsLogin --org development
```

### Azure DevOps OIDC Configuration (Manual)

For Azure DevOps OIDC integration, you need to manually configure `cli/config.mjs`:

1. Copy the sample configuration file:
```bash
cp cli/sample.config.mjs cli/config.mjs
```

2. Edit `cli/config.mjs` with your Azure DevOps settings:

```javascript
export const oidcProviderUrl = 'https://vstoken.dev.azure.com/<your-entra-id-tenant-id>';
export const audience = 'api://AzureADTokenExchange';
export const thumbprint = '<microsoft-certificate-thumbprint>';

// Default policy document - customize based on your needs
export const defaultPolicyDocument = {
  Version: "2012-10-17",
  Statement: [
    {
      Effect: "Allow",
      Action: [
        "s3:ListBucket",
        "sts:AssumeRole", // Required for OIDC roles
        // Add other permissions as needed
      ],
      Resource: "*"
    }
  ]
};
```

**Important:** The `config.mjs` file contains sensitive information and should not be committed to version control.

### Configuration Parameters

#### AWS SSO Parameters
- **REGION**: The AWS region where your Identity Center is configured
- **START_URL**: Your organization's AWS Identity Center start URL
- **ALLOWED_ROLE_NAMES**: Array of role names to include (optional filter)
- **INCLUDE_ACCOUNTS**: Array of account IDs to include (empty array = all accounts)

#### Azure OIDC Parameters
- **oidcProviderUrl**: Your Azure DevOps OIDC provider URL (includes tenant ID)
- **audience**: The audience for token exchange (typically `api://AzureADTokenExchange`)
- **thumbprint**: Microsoft's certificate thumbprint for Azure DevOps
- **defaultPolicyDocument**: IAM policy defining permissions for OIDC roles

## 🔧 Usage

### AWS SSO Login (`awsLogin`)

Authenticate with AWS SSO and retrieve temporary credentials for your accounts and roles:

```bash
awsLogin
```

This command will:
1. Open your browser for SSO authentication
2. List available accounts and roles based on your configuration filters
3. Retrieve temporary credentials for all accessible roles
4. Update your `~/.aws/credentials` and `~/.aws/config` files
5. Create named profiles for each account

### Switch AWS Profile (`awsUseCreds`)

Switch between different AWS profiles as your default:

```bash
awsUseCreds --profile <profile-name>
```

Example:
```bash
awsUseCreds --profile "Production Account"
awsUseCreds --profile "Development Account"
```

This command will:
1. Backup your current credentials
2. Set the specified profile as the default
3. Preserve the previous default profile with a named entry

### Azure DevOps OIDC Setup (`aws-azure-oidc`)

Manage OIDC integration between Azure DevOps and AWS for secure CI/CD workflows.

#### Create OIDC Setup

Create an OIDC provider and IAM role for Azure DevOps integration:

```bash
node cli/awsAzureOIDC.mjs create --org <organization> --project <project> [options]
```

**Required Options:**
- `-o, --org <organization>`: Azure DevOps organization name
- `-p, --project <project>`: Azure DevOps project name

**Optional Options:**
- `-u, --pipeline-user <user>`: Pipeline user name (default: 'azPipelinesUser')
- `--pipeline <pipeline>`: Specific pipeline name (if not provided, allows any pipeline in project)

**Examples:**
```bash
# Create OIDC setup for any pipeline in the project
node cli/awsAzureOIDC.mjs create --org MyOrg --project MyProject

# Create OIDC setup for a specific pipeline
node cli/awsAzureOIDC.mjs create --org MyOrg --project MyProject --pipeline MyPipeline

# Create with custom pipeline user
node cli/awsAzureOIDC.mjs create --org MyOrg --project MyProject --pipeline-user customUser
```

#### Delete OIDC Setup

Remove OIDC integration resources:

```bash
node cli/awsAzureOIDC.mjs delete --org <organization> --project <project> [options]
```

**Options:**
- Same required and optional options as create command
- `-a, --all`: Delete everything including the OIDC provider (⚠️ affects all pipeline users)

**Examples:**
```bash
# Delete role and policy only
node cli/awsAzureOIDC.mjs delete --org MyOrg --project MyProject

# Delete everything including shared OIDC provider
node cli/awsAzureOIDC.mjs delete --org MyOrg --project MyProject --all
```

#### What the OIDC Setup Creates

The OIDC setup process creates:

1. **OIDC Provider**: Establishes trust between AWS and Azure DevOps
2. **IAM Role**: Role that Azure DevOps pipelines can assume
3. **Trust Policy**: Defines which Azure DevOps organizations/projects/pipelines can assume the role
4. **IAM Policy**: Defines permissions for the role (configurable via `defaultPolicyDocument`)

The tool outputs all necessary configuration values for your Azure DevOps service connection.

### AWS Resource Inventory (`awsResourceInventory.sh`)

Generate a comprehensive inventory of AWS resources across regions with estimated monthly costs:

```bash
./awsFinOps/awsResourceInventory.sh [output_file] [regions]
```

**Arguments:**
- `output_file`: Output markdown file (default: `resources.md`)
- `regions`: Comma-separated list of regions (default: all enabled regions)

**Examples:**
```bash
# Scan all regions, output to resources.md
./awsFinOps/awsResourceInventory.sh

# Custom output file
./awsFinOps/awsResourceInventory.sh inventory.md

# Specific regions only
./awsFinOps/awsResourceInventory.sh output.md us-east-1,us-west-2
```

**Resources Scanned:**
- EC2 instances, EBS volumes, AMIs, snapshots
- RDS instances and clusters
- Lambda functions
- S3 buckets
- DynamoDB tables
- ElastiCache clusters
- Load balancers (ALB, NLB, Classic)
- NAT Gateways
- ECS/EKS clusters
- VPCs and networking resources
- And more...

**Output:**
- Markdown report with resource details
- Estimated monthly costs per resource
- Total cost summary

### AWS Account Cleanup (`awsCleanup.sh`)

⚠️ **WARNING: This script permanently deletes resources. Only use on sandbox/test accounts.**

Delete all resources in an AWS account for cleanup purposes:

```bash
./awsCleanup/awsCleanup.sh
```

**Features:**
- Requires confirmation by typing `DELETE EVERYTHING`
- 10-second countdown before each deletion (Ctrl+C to abort)
- Targets `ca-central-1` and `us-east-1` regions (configurable in script)
- Deletes resources in dependency order to avoid conflicts

**Resources Deleted:**
- CloudFormation stacks
- ECS/EKS clusters and services
- EC2 instances and Auto Scaling Groups
- Load balancers (ALB, NLB, Classic)
- RDS instances and clusters
- ElastiCache clusters
- Lambda functions
- DynamoDB tables
- SQS queues and SNS topics
- ECR repositories
- Secrets Manager secrets
- SSM parameters
- CloudWatch Log Groups
- S3 buckets (including versioned objects)
- VPCs and networking (NAT Gateways, IGWs, subnets)
- IAM users (global)
- Lightsail resources

## 📁 File Structure

```
awsIdentityTools/
├── cli/
│   ├── awsLogin.mjs         # SSO authentication tool
│   ├── awsUseCreds.mjs      # Profile switching tool
│   ├── awsAzureOIDC.mjs     # Azure DevOps OIDC management tool
│   ├── config.mjs           # Configuration file (create from sample, not in repo)
│   ├── sample.config.mjs    # Configuration template
│   └── setup.mjs            # Setup utilities
├── src/
│   └── AzureOIDCSetup.mjs   # OIDC setup class implementation
├── awsCleanup/
│   └── awsCleanup.sh        # AWS account resource cleanup script
├── awsFinOps/
│   └── awsResourceInventory.sh  # Resource inventory and cost estimation
├── dist/                    # Compiled executables (generated)
├── build.js                 # Build script
├── package.json             # Package configuration
├── LICENSE                  # GNU GPL v3 License
└── README.md                # This file
```

**Important**: The `config.mjs` file contains sensitive information (URLs, tenant IDs, etc.) and should not be committed to version control. Always use `sample.config.mjs` as a template and create your own `config.mjs` file.

## 🛠️ Development

### Building

To rebuild the project after making changes:

```bash
npm run compile
```

This will:
1. Bundle the CLI tools using esbuild
2. Add executable permissions
3. Create distributable files in the `dist/` directory

### Testing

```bash
npm test
```

## 🔍 Troubleshooting

### Installation Issues

**Error: `npm ERR! EEXIST: file already exists`**

If you encounter this error:
```
npm ERR! EEXIST: file already exists
npm ERR! File exists: /usr/local/bin/awsUseCreds
```

This means you have a previous installation. To resolve:

```bash
rm /usr/local/bin/awsUseCreds
rm /usr/local/bin/awsLogin
npm run setup
```

### Common Issues

1. **"AWS credentials file not found"**
   - Ensure you have run `aws configure` at least once or have an existing `~/.aws/credentials` file

2. **"Profile not found"**
   - Check that the profile name exists in your credentials file
   - Use `awsLogin` to create new profiles

3. **SSO Authentication Fails**
   - Verify your `START_URL` in `config.mjs`
   - Ensure your Identity Center region is correct
   - Check that you have the necessary permissions in your AWS organization

4. **OIDC Setup Issues**
   - Ensure AWS CLI is installed and configured
   - Verify you have IAM permissions to create OIDC providers and roles
   - Check that your `oidcProviderUrl` is correct for your Azure DevOps organization
   - Ensure the thumbprint matches Microsoft's current certificate

5. **Azure DevOps Integration Issues**
   - Verify the organization and project names are correct
   - Check that the generated trust policy matches your Azure DevOps setup
   - Ensure your service connection configuration matches the output from the tool

### Shell Script Issues

1. **"jq: command not found" or "bc: command not found"**
   - Install required tools: `sudo apt install jq bc` (Linux) or `brew install jq bc` (macOS)

2. **"AWS credentials are not configured or invalid"**
   - Run `aws sts get-caller-identity` to verify credentials
   - Use `awsLogin` to authenticate via SSO, or configure credentials manually

3. **Cleanup script hangs or times out**
   - Some resources take time to delete (e.g., RDS, EKS)
   - Press Ctrl+C during countdown to skip a specific resource
   - Check AWS Console for deletion progress

4. **Resource inventory missing resources**
   - Ensure your AWS credentials have read permissions for all services
   - Check if resources are in regions not being scanned

### Configuration Issues

1. **Missing config.mjs file**
   - Copy `sample.config.mjs` to `config.mjs` and update with your values
   - Ensure all required fields are configured

2. **Invalid tenant ID or thumbprint**
   - Verify your Azure Entra ID tenant ID in the OIDC provider URL
   - Check Microsoft's documentation for the current certificate thumbprint

## 📝 License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## 📚 Dependencies

### Node.js Dependencies
- **@aws-sdk/client-iam**: AWS IAM client for managing roles and policies
- **@aws-sdk/client-sso**: AWS SSO client for authentication
- **@aws-sdk/client-sso-oidc**: AWS SSO OIDC client for token management
- **@aws-sdk/client-sts**: AWS STS client for credential operations
- **commander**: Command-line interface framework
- **inquirer**: Interactive command-line prompts
- **ini**: INI file parser for AWS credentials/config files
- **dotenv**: Environment variable loader

### Shell Script Dependencies
- **AWS CLI v2**: Required for all shell scripts
- **jq**: JSON processor for parsing AWS CLI output
- **bc**: Calculator for cost computations

## 🔐 Security

- **Credentials**: Stored in the standard AWS credentials file (`~/.aws/credentials`)
- **Backup**: Automatic backup is created before modifying credentials
- **SSO Tokens**: Managed securely through AWS SDK
- **OIDC Trust**: Dynamic trust policies with organization/project/pipeline scoping
- **Configuration**: Sensitive configuration excluded from version control
- **Principle of Least Privilege**: Configurable IAM policies to limit permissions

### Security Best Practices

1. **Keep config.mjs secure**: Never commit this file to version control
2. **Limit IAM permissions**: Configure `defaultPolicyDocument` with minimal required permissions
3. **Use specific trust policies**: Specify exact organizations, projects, and pipelines when possible
4. **Regular rotation**: Periodically review and rotate OIDC configurations
5. **Monitor usage**: Use AWS CloudTrail to monitor role assumptions

## 🎯 Use Cases

### AWS SSO Management
- **Multi-account organizations**: Easily switch between different AWS accounts
- **Role-based access**: Manage multiple roles across accounts
- **Temporary credentials**: Automatic handling of short-lived tokens

### CI/CD Integration
- **Azure DevOps**: Secure integration without long-lived credentials
- **Pipeline isolation**: Separate roles for different projects/pipelines
- **Cross-account deployment**: Deploy to multiple AWS accounts from Azure DevOps

### FinOps & Cost Management
- **Resource auditing**: Generate comprehensive inventory reports
- **Cost estimation**: Understand monthly costs across all regions
- **Compliance reporting**: Document all resources in an account
- **Budget planning**: Estimate costs before provisioning

### Account Maintenance
- **Sandbox cleanup**: Reset test/development accounts
- **Cost control**: Remove unused resources to reduce costs
- **Decommissioning**: Clean up accounts before closure

### Development Workflows
- **Local development**: Easy switching between development/staging/production accounts
- **Team collaboration**: Standardized credential management across teams
- **Security compliance**: Reduce long-lived credential usage

## 📈 Version History

- **v1.0.4**: Current version with enhanced profile management and SSO support
