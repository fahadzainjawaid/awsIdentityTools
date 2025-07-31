# AWS Identity Tools

A comprehensive collection of Node.js CLI tools for managing AWS credentials, authentication, and Azure DevOps OIDC integration with AWS. This toolkit simplifies AWS SSO login, credential management, and automated CI/CD workflows.

## 🚀 Features

- **AWS SSO Authentication**: Streamlined login process using AWS Identity Center (SSO)
- **Profile Management**: Easy switching between AWS profiles
- **Azure DevOps OIDC Integration**: Automated setup and management of OIDC providers for Azure DevOps pipelines
- **Credential Backup**: Automatic backup of existing credentials before making changes
- **Multi-Account Support**: Work with multiple AWS accounts and roles
- **Interactive Setup**: User-friendly prompts for configuration
- **Trust Policy Management**: Dynamic trust policy generation for secure OIDC authentication

## 📦 Installation

### Prerequisites

- Node.js (version 14 or higher)
- npm
- An AWS account with AWS Identity Center (SSO) configured
- AWS CLI installed and configured (for OIDC setup features)
- Azure DevOps organization (for OIDC integration features)

### Installation

1. Clone this repository:
```bash
git clone <repository-url>
cd awsUseCreds
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

## ⚙️ Configuration

Before using the tools, you need to configure your settings. **Important: The configuration file contains sensitive information and should not be committed to version control.**

### Initial Setup

1. Copy the sample configuration file:
```bash
cp cli/sample.config.mjs cli/config.mjs
```

2. Edit `cli/config.mjs` with your specific settings:

#### AWS Identity Center Configuration
```javascript
export const REGION = 'us-east-1'; // Your Identity Center region
export const START_URL = 'https://your-identity-center.awsapps.com/start';

// Optional: restrict which roles or accounts to fetch
export const ALLOWED_ROLE_NAMES = ["AdministratorAccess", "PowerUserAccess"];
export const INCLUDE_ACCOUNTS = []; // Empty = all accounts
```

#### Azure DevOps OIDC Configuration
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

## 📁 File Structure

```
awsUseCreds/
├── cli/
│   ├── awsLogin.mjs         # SSO authentication tool
│   ├── awsUseCreds.mjs      # Profile switching tool
│   ├── awsAzureOIDC.mjs     # Azure DevOps OIDC management tool
│   ├── config.mjs           # Configuration file (create from sample, not in repo)
│   └── sample.config.mjs    # Configuration template
├── src/
│   └── AzureOIDCSetup.mjs   # OIDC setup class implementation
├── dist/                    # Compiled executables
├── build.js                 # Build script
├── package.json             # Package configuration
└── README.md               # This file
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

- **@aws-sdk/client-iam**: AWS IAM client for managing roles and policies
- **@aws-sdk/client-sso**: AWS SSO client for authentication
- **@aws-sdk/client-sso-oidc**: AWS SSO OIDC client for token management
- **@aws-sdk/client-sts**: AWS STS client for credential operations
- **commander**: Command-line interface framework
- **inquirer**: Interactive command-line prompts
- **ini**: INI file parser for AWS credentials/config files
- **dotenv**: Environment variable loader

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

### Development Workflows
- **Local development**: Easy switching between development/staging/production accounts
- **Team collaboration**: Standardized credential management across teams
- **Security compliance**: Reduce long-lived credential usage

## 📈 Version History

- **v1.0.4**: Current version with enhanced profile management and SSO support
