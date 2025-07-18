import {
  RegisterClientCommand,
  StartDeviceAuthorizationCommand,
  CreateTokenCommand,
  SSOOIDCClient
} from "@aws-sdk/client-sso-oidc";

import {
  SSOClient,
  ListAccountsCommand,
  ListAccountRolesCommand,
  GetRoleCredentialsCommand
} from "@aws-sdk/client-sso";

import fs from "fs";
import os from "os";
import path from "path";
import ini from "ini";
import {
  REGION,
  START_URL,
  ALLOWED_ROLE_NAMES,
  INCLUDE_ACCOUNTS
} from "./config.mjs";

const oidcClient = new SSOOIDCClient({ region: REGION });
const ssoClient = new SSOClient({ region: REGION });

async function authenticateUser() {
  const { clientId, clientSecret } = await oidcClient.send(
    new RegisterClientCommand({
      clientName: "aws-sso-script",
      clientType: "public",
      scopes: ["sso:account:access"]
    })
  );

  const deviceRes = await oidcClient.send(
    new StartDeviceAuthorizationCommand({
      clientId,
      clientSecret,
      startUrl: START_URL
    })
  );

  console.log("\n🔐 Please log in using your browser:");
  console.log(`👉  \x1b[36m${deviceRes.verificationUriComplete}\x1b[0m\n`);

  let token;
  while (!token) {
    try {
      const tokenRes = await oidcClient.send(
        new CreateTokenCommand({
          grantType: "urn:ietf:params:oauth:grant-type:device_code",
          deviceCode: deviceRes.deviceCode,
          clientId,
          clientSecret
        })
      );
      token = tokenRes;
    } catch (e) {
      if (e.name === "AuthorizationPendingException") {
        await new Promise((r) => setTimeout(r, deviceRes.interval * 1000));
      } else {
        throw e;
      }
    }
  }

  return token;
}

async function listAllRoles(accessToken) {
  const accountMap = new Map();
  let nextToken;

  do {
    const res = await ssoClient.send(new ListAccountsCommand({ accessToken, nextToken }));
    for (const account of res.accountList) {
      if (INCLUDE_ACCOUNTS.length && !INCLUDE_ACCOUNTS.includes(account.accountId)) continue;
      accountMap.set(account.accountId, account.accountName);
    }
    nextToken = res.nextToken;
  } while (nextToken);

  const roles = [];

  for (const [accountId, accountName] of accountMap.entries()) {
    let roleToken;
    do {
      const res = await ssoClient.send(
        new ListAccountRolesCommand({ accessToken, accountId, nextToken: roleToken })
      );

      for (const role of res.roleList) {
        if (!ALLOWED_ROLE_NAMES.length || ALLOWED_ROLE_NAMES.includes(role.roleName)) {
          roles.push({
            accountId,
            accountName,
            roleName: role.roleName
          });
        }
      }

      roleToken = res.nextToken;
    } while (roleToken);
  }

  return roles;
}

async function fetchCredentialsForRoles(accessToken, roles) {
  const credentialsList = [];

  for (const { accountId, roleName, accountName } of roles) {
    const res = await ssoClient.send(
      new GetRoleCredentialsCommand({ accessToken, accountId, roleName })
    );

    const creds = res.roleCredentials;
    credentialsList.push({
      accountId,
      roleName,
      accountName,
      accessKeyId: creds.accessKeyId,
      secretAccessKey: creds.secretAccessKey,
      sessionToken: creds.sessionToken,
      expiration: creds.expiration
    });

    console.log(`✅ Retrieved credentials for ${accountId}/${roleName}`);
  }

  return credentialsList;
}

function sanitizeProfileName(name) {
  // Replace newlines or control chars with space, trim whitespace
  return name.replace(/[\r\n]/g, " ").trim();
}

function generateProfileName(cred) {
  // Format: "accountId-roleName-accountName"
  // accountName can have spaces here (AWS CLI supports spaces in [ ])
  return `${sanitizeProfileName(cred.accountName)}`;
}

function writeToCredentialsFile(credsList) {
  const awsDir = path.join(os.homedir(), ".aws");
  const filePath = path.join(awsDir, "credentials");

  if (!fs.existsSync(awsDir)) {
    fs.mkdirSync(awsDir, { recursive: true });
    console.log(`📂 Created AWS config directory: ${awsDir}`);
  }

  // Read existing credentials file if exists
  let existing = {};
  if (fs.existsSync(filePath)) {
    const content = fs.readFileSync(filePath, "utf-8");
    existing = ini.parse(content);
  }

  // Remove profiles matching our generated profile names
  for (const cred of credsList) {
    const profileName = generateProfileName(cred);
    if (existing[profileName]) {
      delete existing[profileName];
      console.log(`🗑 Removed old profile: [${profileName}]`);
    }
  }

  // Add fresh profiles
  for (const cred of credsList) {
    const profileName = generateProfileName(cred);
    existing[profileName] = {
      aws_access_key_id: cred.accessKeyId,
      aws_secret_access_key: cred.secretAccessKey,
      aws_session_token: cred.sessionToken,
      profile: cred.accountName
    };
    console.log(`➕ Added profile: [${profileName}]`);
  }

  fs.writeFileSync(filePath, ini.stringify(existing));
  console.log(`\n📝 Credentials updated at ${filePath}`);
}

function writeToConfigFile(credsList) {
  const awsDir = path.join(os.homedir(), ".aws");
  const filePath = path.join(awsDir, "config");

  if (!fs.existsSync(awsDir)) {
    fs.mkdirSync(awsDir, { recursive: true });
    console.log(`📂 Created AWS config directory: ${awsDir}`);
  }

  // Read existing config file if exists
  let existing = {};
  if (fs.existsSync(filePath)) {
    const content = fs.readFileSync(filePath, "utf-8");
    existing = ini.parse(content);
  }

  // Remove old profile sections
  for (const cred of credsList) {
    const profileName = generateProfileName(cred);
    const sectionName = `profile ${profileName}`;
    if (existing[sectionName]) {
      delete existing[sectionName];
      console.log(`🗑 Removed old config section: [${sectionName}]`);
    }
  }

  // Add fresh profile sections
  for (const cred of credsList) {
    const profileName = generateProfileName(cred);
    const sectionName = `profile ${profileName}`;
    existing[sectionName] = {
      region: REGION,
      output: "json"
    };
    console.log(`➕ Added config section: [${sectionName}]`);
  }

  fs.writeFileSync(filePath, ini.stringify(existing));
  console.log(`\n📝 Config updated at ${filePath}`);
}

(async () => {
  try {
    const token = await authenticateUser();
    const roles = await listAllRoles(token.accessToken);
    if (!roles.length) {
      console.log("⚠️ No roles found matching your filters.");
      return;
    }
    const credsList = await fetchCredentialsForRoles(token.accessToken, roles);
    writeToCredentialsFile(credsList);
    writeToConfigFile(credsList);
  } catch (err) {
    console.error("❌ Error:", err);
  }
})();
