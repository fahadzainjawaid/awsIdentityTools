import * as fs from 'fs';
import * as path from 'path';
import { homedir } from 'os';

const CONFIG_PATH = path.join(homedir(), '.aws', 'awsIdentityConfig.json');

function loadConfigFile() {
  if (!fs.existsSync(CONFIG_PATH)) {
    console.error('\n❌ Configuration file not found!');
    console.error(`   Expected location: ${CONFIG_PATH}`);
    console.error('\n   Please run setup first:');
    console.error('   node cli/setup.mjs\n');
    process.exit(1);
  }

  try {
    const content = fs.readFileSync(CONFIG_PATH, 'utf-8');
    return JSON.parse(content);
  } catch (error) {
    console.error('\n❌ Failed to read configuration file!');
    console.error(`   Error: ${error.message}`);
    console.error('\n   Please run setup again:');
    console.error('   node cli/setup.mjs\n');
    process.exit(1);
  }
}

/**
 * Get configuration for a specific org.
 * @param {string} [orgName] - The org name. If not provided, uses the first org.
 * @returns {Object} The configuration object with REGION, START_URL, ALLOWED_ROLE_NAMES, INCLUDE_ACCOUNTS
 */
export function getConfig(orgName) {
  const configFile = loadConfigFile();
  
  if (!configFile.orgs || Object.keys(configFile.orgs).length === 0) {
    console.error('\n❌ No orgs configured!');
    console.error('\n   Please run setup to add an org:');
    console.error('   node cli/setup.mjs\n');
    process.exit(1);
  }

  const orgNames = Object.keys(configFile.orgs);
  
  // If no org specified, use the first one
  const selectedOrg = orgName || orgNames[0];
  
  if (!configFile.orgs[selectedOrg]) {
    console.error(`\n❌ Org "${selectedOrg}" not found!`);
    console.error(`\n   Available orgs: ${orgNames.join(', ')}`);
    console.error('\n   Use --org <name> to specify an org, or run setup to add one:');
    console.error('   node cli/setup.mjs\n');
    process.exit(1);
  }

  const orgConfig = configFile.orgs[selectedOrg];
  
  console.log(`📁 Using org: ${selectedOrg}`);
  
  return {
    REGION: orgConfig.REGION,
    START_URL: orgConfig.START_URL,
    ALLOWED_ROLE_NAMES: orgConfig.ALLOWED_ROLE_NAMES || [],
    INCLUDE_ACCOUNTS: orgConfig.INCLUDE_ACCOUNTS || []
  };
}

/**
 * List all available org names.
 * @returns {string[]} Array of org names
 */
export function listOrgs() {
  const configFile = loadConfigFile();
  return Object.keys(configFile.orgs || {});
}

/**
 * Get OIDC configuration.
 * @returns {Object} The OIDC configuration object
 */
export function getOIDCConfig() {
  const configFile = loadConfigFile();
  return configFile.oidc || {};
}

// OIDC configuration exports (loaded from config file)
const oidcConfig = (() => {
  try {
    if (fs.existsSync(CONFIG_PATH)) {
      const content = fs.readFileSync(CONFIG_PATH, 'utf-8');
      const config = JSON.parse(content);
      return config.oidc || {};
    }
  } catch (error) {
    // Config not available yet, return empty
  }
  return {};
})();

export const oidcProviderUrl = oidcConfig.oidcProviderUrl || '';
export const audience = oidcConfig.audience || 'api://AzureADTokenExchange';
export const thumbprint = oidcConfig.thumbprint || '';

// Function to get role and policy names based on pipeline user
export const getRoleName = (pipelineUser) => 
  oidcConfig.roleNamePattern 
    ? oidcConfig.roleNamePattern.replace('{pipelineUser}', pipelineUser)
    : `${pipelineUser}-OIDCRole`;

export const getPolicyName = (pipelineUser) => 
  oidcConfig.policyNamePattern
    ? oidcConfig.policyNamePattern.replace('{pipelineUser}', pipelineUser)
    : `${pipelineUser}-OIDCPolicy`;

// Default policy document for OIDC roles
export const defaultPolicyDocument = oidcConfig.defaultPolicyDocument || {
  Version: "2012-10-17",
  Statement: [
    {
      "Effect": "Allow",
      "Action": [
        "s3:ListBucket",
        "sts:AssumeRole",
        "lightsail:*",
        "route53:*",
        "secretsmanager:*"
      ],
      "Resource": "*"
    }
  ]
};
