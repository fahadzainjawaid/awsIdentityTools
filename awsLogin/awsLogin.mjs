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
import {
  REGION,
  START_URL,
  ALLOWED_ROLE_NAMES,
  INCLUDE_ACCOUNTS
} from "./config.mjs";

// Clients
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
  const accounts = [];
  let nextToken;

  do {
    const res = await ssoClient.send(new ListAccountsCommand({ accessToken, nextToken }));
    accounts.push(...res.accountList);
    nextToken = res.nextToken;
  } while (nextToken);

  const roles = [];

  for (const account of accounts) {
    const accountId = account.accountId;
    if (INCLUDE_ACCOUNTS.length && !INCLUDE_ACCOUNTS.includes(accountId)) continue;

    let roleToken;
    do {
      const res = await ssoClient.send(
        new ListAccountRolesCommand({ accessToken, accountId, nextToken: roleToken })
      );

      for (const role of res.roleList) {
        if (!ALLOWED_ROLE_NAMES.length || ALLOWED_ROLE_NAMES.includes(role.roleName)) {
          roles.push({ accountId, roleName: role.roleName });
        }
      }

      roleToken = res.nextToken;
    } while (roleToken);
  }

  return roles;
}

async function fetchCredentialsForRoles(accessToken, roles) {
  const credentialsList = [];

  for (const { accountId, roleName } of roles) {
    const res = await ssoClient.send(
      new GetRoleCredentialsCommand({ accessToken, accountId, roleName })
    );

    const creds = res.roleCredentials;
    credentialsList.push({
      accountId,
      roleName,
      accessKeyId: creds.accessKeyId,
      secretAccessKey: creds.secretAccessKey,
      sessionToken: creds.sessionToken,
      expiration: creds.expiration
    });

    console.log(`✅ Retrieved credentials for ${accountId}/${roleName}`);
  }

  return credentialsList;
}

function writeToCredentialsFile(credsList) {
  const filePath = path.join(os.homedir(), ".aws", "credentials");
  const lines = [];

  for (const cred of credsList) {
    const profile = `${cred.accountId}-${cred.roleName}`;
    lines.push(
      `[${profile}]
aws_access_key_id = ${cred.accessKeyId}
aws_secret_access_key = ${cred.secretAccessKey}
aws_session_token = ${cred.sessionToken}
`
    );
  }

  fs.appendFileSync(filePath, lines.join("\n"));
  console.log(`\n📝 Credentials written to ${filePath}\n`);
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
  } catch (err) {
    console.error("❌ Error:", err);
  }
})();
