import * as fs from 'fs';
import * as path from 'path';
import { homedir } from 'os';

const CONFIG_PATH = path.join(homedir(), '.aws', 'awsIdentityConfig.json');

function loadConfigFile() {
  if (!fs.existsSync(CONFIG_PATH)) {
    console.error('\n❌ Configuration file not found!');
    console.error(`   Expected location: ${CONFIG_PATH}`);
    console.error('\n   Please run setup first:');
    console.error('   node cli/configure.mjs\n');
    process.exit(1);
  }

  try {
    const content = fs.readFileSync(CONFIG_PATH, 'utf-8');
    return JSON.parse(content);
  } catch (error) {
    console.error('\n❌ Failed to read configuration file!');
    console.error(`   Error: ${error.message}`);
    console.error('\n   Please run setup again:');
    console.error('   node cli/configure.mjs\n');
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
    console.error('   node cli/configure.mjs\n');
    process.exit(1);
  }

  const orgNames = Object.keys(configFile.orgs);
  
  // If no org specified, use the first one
  const selectedOrg = orgName || orgNames[0];
  
  if (!configFile.orgs[selectedOrg]) {
    console.error(`\n❌ Org "${selectedOrg}" not found!`);
    console.error(`\n   Available orgs: ${orgNames.join(', ')}`);
    console.error('\n   Use --org <name> to specify an org, or run setup to add one:');
    console.error('   node cli/configure.mjs\n');
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

// Matches angle-bracket placeholders left over from the sample config,
// e.g. "<your entra ID tenant ID>" or "<certificate thumbprint>".
const PLACEHOLDER_RE = /[<>]/;

/**
 * Fail loudly if a required OIDC value is empty or still a placeholder.
 * @param {*} value - The value to validate
 * @param {string} field - The field name (for the error message)
 * @param {string} orgName - The Azure DevOps org this value belongs to
 */
function requireOIDCValue(value, field, orgName) {
  const str = value === undefined || value === null ? '' : String(value).trim();
  if (str === '' || PLACEHOLDER_RE.test(str)) {
    console.error(`\n❌ OIDC configuration error for org "${orgName}".`);
    console.error(`   Required field "${field}" is missing or still a placeholder.`);
    console.error(`   Current value: ${JSON.stringify(value)}`);
    console.error(`\n   Fix it at: ${CONFIG_PATH}`);
    console.error(`   under oidc.orgs.${orgName}.${field}\n`);
    process.exit(1);
  }
}

/**
 * Resolve the OIDC configuration for a single Azure DevOps org.
 *
 * Supports a multi-org layout (oidc.orgs.<name> = { oidcProviderUrl, audience,
 * thumbprint }) and falls back to a legacy flat oidc block as a single org.
 * Crashes with a clear message if required values are empty/placeholder, if the
 * requested org is missing, or if multiple orgs exist and none was specified.
 *
 * @param {string} [orgName] - Azure DevOps org name. Optional only when exactly one org is configured.
 * @returns {{org: string, oidcProviderUrl: string, audience: string, thumbprint: string}}
 */
export function getOIDCOrgConfig(orgName) {
  const configFile = loadConfigFile();
  const oidc = configFile.oidc || {};

  // Resolve the available orgs. Prefer the nested layout; fall back to a
  // legacy flat oidc block treated as a single org.
  let orgs = oidc.orgs;
  if (!orgs || Object.keys(orgs).length === 0) {
    if (oidc.oidcProviderUrl) {
      orgs = {
        [orgName || 'default']: {
          oidcProviderUrl: oidc.oidcProviderUrl,
          audience: oidc.audience,
          thumbprint: oidc.thumbprint
        }
      };
    } else {
      console.error('\n❌ No OIDC orgs configured!');
      console.error(`   Add an "oidc.orgs" section to: ${CONFIG_PATH}\n`);
      process.exit(1);
    }
  }

  const names = Object.keys(orgs);

  // Pick the org: explicit --org, or the sole org if there's only one.
  let selected = orgName;
  if (!selected) {
    if (names.length === 1) {
      selected = names[0];
    } else {
      console.error('\n❌ Multiple OIDC orgs are configured — choose one with --org <name>.');
      console.error(`   Available orgs: ${names.join(', ')}\n`);
      process.exit(1);
    }
  }

  if (!orgs[selected]) {
    console.error(`\n❌ OIDC org "${selected}" not found!`);
    console.error(`   Available orgs: ${names.join(', ')}\n`);
    process.exit(1);
  }

  const orgCfg = orgs[selected];
  const resolved = {
    org: selected,
    oidcProviderUrl: orgCfg.oidcProviderUrl,
    audience: orgCfg.audience || oidc.audience || 'api://AzureADTokenExchange',
    thumbprint: orgCfg.thumbprint
  };

  // Required values must be real, or we stop here rather than building a
  // broken role (an empty url/thumbprint silently corrupted past runs).
  requireOIDCValue(resolved.oidcProviderUrl, 'oidcProviderUrl', selected);
  requireOIDCValue(resolved.audience, 'audience', selected);
  requireOIDCValue(resolved.thumbprint, 'thumbprint', selected);

  console.log(`🔗 Using Azure DevOps org: ${selected}`);
  return resolved;
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

// Default policy document for OIDC roles.
//
// ⚠️ ILLUSTRATIVE ONLY — this default is intentionally broad to get you started
// and is NOT meant for production use. It grants wildcard actions on several
// services against all resources ("Resource": "*"), which violates least
// privilege. Override it for your environment by setting `oidc.defaultPolicyDocument`
// in ~/.aws/awsIdentityConfig.json, scoped to the specific actions and resource
// ARNs your pipeline actually needs.
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
