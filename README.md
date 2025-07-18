# AWS Identity Tools

A collection of Node.js CLI tools for managing AWS credentials and authentication, designed to simplify AWS SSO login and credential management workflows.

## 🚀 Features

- **AWS SSO Authentication**: Streamlined login process using AWS Identity Center (SSO)
- **Profile Management**: Easy switching between AWS profiles
- **Credential Backup**: Automatic backup of existing credentials before making changes
- **Multi-Account Support**: Work with multiple AWS accounts and roles
- **Interactive Setup**: User-friendly prompts for configuration

## 📦 Installation

### Prerequisites

- Node.js (version 14 or higher)
- npm
- An AWS account with AWS Identity Center (SSO) configured

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

Before using the tools, you need to configure your AWS Identity Center settings:

1. Copy the sample configuration file:
```bash
cp cli/sample.config.mjs cli/config.mjs
```

2. Edit `cli/config.mjs` with your specific settings:
```javascript
export const REGION = 'us-east-1'; // Your Identity Center region
export const START_URL = 'https://your-identity-center.awsapps.com/start';

// Optional: restrict which roles or accounts to fetch
export const ALLOWED_ROLE_NAMES = ["AdministratorAccess", "PowerUserAccess"];
export const INCLUDE_ACCOUNTS = []; // Empty = all accounts
```

### Configuration Parameters

- **REGION**: The AWS region where your Identity Center is configured
- **START_URL**: Your organization's AWS Identity Center start URL
- **ALLOWED_ROLE_NAMES**: Array of role names to include (optional filter)
- **INCLUDE_ACCOUNTS**: Array of account IDs to include (empty array = all accounts)

## 🔧 Usage

### AWS SSO Login (`awsLogin`)

Authenticate with AWS SSO and retrieve temporary credentials for your accounts and roles:

```bash
awsLogin
```

This command will:
1. Open your browser for SSO authentication
2. List available accounts and roles
3. Allow you to select which credentials to save
4. Update your `~/.aws/credentials` file

### Switch AWS Profile (`awsUseCreds`)

Switch between different AWS profiles as your default:

```bash
awsUseCreds --profile <profile-name>
```

Example:
```bash
awsUseCreds --profile production-admin
awsUseCreds --profile dev-poweruser
```

This command will:
1. Backup your current credentials
2. Set the specified profile as the default
3. Preserve the previous default profile with a named entry

## 📁 File Structure

```
awsUseCreds/
├── cli/
│   ├── awsLogin.mjs         # SSO authentication tool
│   ├── awsUseCreds.mjs      # Profile switching tool
│   ├── config.mjs           # Configuration file (you create this)
│   └── sample.config.mjs    # Configuration template
├── dist/                    # Compiled executables
├── build.js                 # Build script
├── package.json             # Package configuration
└── README.md               # This file
```

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

## 📝 License

This project is licensed under the GNU General Public License v3.0 - see the [LICENSE](LICENSE) file for details.

## 🤝 Contributing

1. Fork the repository
2. Create a feature branch
3. Make your changes
4. Test thoroughly
5. Submit a pull request

## 📚 Dependencies

- **@aws-sdk/client-iam**: AWS IAM client
- **@aws-sdk/client-sso**: AWS SSO client
- **@aws-sdk/client-sso-oidc**: AWS SSO OIDC client
- **@aws-sdk/client-sts**: AWS STS client
- **commander**: Command-line interface framework
- **inquirer**: Interactive command-line prompts
- **ini**: INI file parser
- **dotenv**: Environment variable loader

## 🔐 Security

- Credentials are stored in the standard AWS credentials file (`~/.aws/credentials`)
- Automatic backup is created before modifying credentials
- SSO tokens are managed securely through AWS SDK
- No sensitive information is logged or stored in plain text

## 📈 Version History

- **v1.0.4**: Current version with enhanced profile management and SSO support
