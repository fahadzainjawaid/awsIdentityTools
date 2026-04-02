#!/usr/bin/env node
import * as readline from 'readline';
import * as fs from 'fs';
import * as path from 'path';
import { homedir } from 'os';

const CONFIG_DIR = path.join(homedir(), '.aws');
const CONFIG_PATH = path.join(CONFIG_DIR, 'awsIdentityConfig.json');

const rl = readline.createInterface({
  input: process.stdin,
  output: process.stdout
});

function question(prompt, defaultValue = '') {
  const defaultText = defaultValue ? ` (default: ${defaultValue})` : '';
  return new Promise((resolve) => {
    rl.question(`${prompt}${defaultText}: `, (answer) => {
      resolve(answer.trim() || defaultValue);
    });
  });
}

function questionArray(prompt, defaultValue = []) {
  const defaultText = defaultValue.length > 0 ? ` (default: ${JSON.stringify(defaultValue)})` : ' (comma-separated, leave empty for none)';
  return new Promise((resolve) => {
    rl.question(`${prompt}${defaultText}: `, (answer) => {
      if (!answer.trim()) {
        resolve(defaultValue);
      } else {
        const items = answer.split(',').map(item => item.trim()).filter(item => item.length > 0);
        resolve(items);
      }
    });
  });
}

async function loadExistingConfig() {
  try {
    if (fs.existsSync(CONFIG_PATH)) {
      const content = fs.readFileSync(CONFIG_PATH, 'utf-8');
      return JSON.parse(content);
    }
  } catch (error) {
    // Ignore errors, return defaults
  }
  return { orgs: {} };
}

async function setup() {
  console.log('\n=== AWS Identity Tools Setup ===\n');
  console.log('This will configure your AWS Identity Center settings.');
  console.log(`Configuration will be saved to: ${CONFIG_PATH}\n`);

  // Load existing config
  const existingConfig = await loadExistingConfig();
  
  // Ensure orgs object exists
  if (!existingConfig.orgs) {
    existingConfig.orgs = {};
  }

  const existingOrgs = Object.keys(existingConfig.orgs);
  if (existingOrgs.length > 0) {
    console.log(`Existing orgs: ${existingOrgs.join(', ')}\n`);
  }

  // Prompt for org name
  const orgName = await question('Org name (identifier for this configuration)', existingOrgs[0] || 'default');
  
  // Get existing org config for defaults
  const existingOrgConfig = existingConfig.orgs[orgName] || {};

  const orgConfig = {};

  // Prompt for each configuration item
  orgConfig.REGION = await question(
    'AWS Region (your Identity Center region)',
    existingOrgConfig.REGION || 'us-east-1'
  );

  orgConfig.START_URL = await question(
    'AWS SSO Start URL',
    existingOrgConfig.START_URL || ''
  );

  orgConfig.ALLOWED_ROLE_NAMES = await questionArray(
    'Allowed role names',
    existingOrgConfig.ALLOWED_ROLE_NAMES || ['AdministratorAccess', 'PowerUserAccess']
  );

  orgConfig.INCLUDE_ACCOUNTS = await questionArray(
    'Include specific account IDs (empty = all accounts)',
    existingOrgConfig.INCLUDE_ACCOUNTS || []
  );

  rl.close();

  // Update the org in config
  existingConfig.orgs[orgName] = orgConfig;

  // Ensure .aws directory exists
  if (!fs.existsSync(CONFIG_DIR)) {
    fs.mkdirSync(CONFIG_DIR, { recursive: true });
    console.log(`\nCreated directory: ${CONFIG_DIR}`);
  }

  // Write configuration file
  fs.writeFileSync(CONFIG_PATH, JSON.stringify(existingConfig, null, 2));
  console.log(`\nConfiguration saved to: ${CONFIG_PATH}`);
  console.log(`\nOrg "${orgName}" configured successfully!`);
  console.log('\nUsage:');
  console.log(`  node cli/awsLogin.mjs                  # Uses first org (${Object.keys(existingConfig.orgs)[0]})`);
  console.log(`  node cli/awsLogin.mjs --org ${orgName}   # Uses "${orgName}" org`);
}

setup().catch((error) => {
  console.error('Setup failed:', error.message);
  rl.close();
  process.exit(1);
});
