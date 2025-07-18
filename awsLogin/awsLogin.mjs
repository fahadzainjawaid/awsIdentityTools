import {
  RegisterClientCommand,
  StartDeviceAuthorizationCommand,
  CreateTokenCommand,
  SSOOIDCClient
} from "@aws-sdk/client-sso-oidc";

import { REGION, START_URL } from "./config.mjs"; // Ensure this file exports REGION and START_URL
// import clipboardy from "clipboardy"; // optional

const oidcClient = new SSOOIDCClient({ region: REGION });

async function authenticateUser() {
  // Step 1: Register the client
  const { clientId, clientSecret } = await oidcClient.send(
    new RegisterClientCommand({
      clientName: "aws-sso-nodejs-script",
      clientType: "public",
      scopes: ["sso:account:access"]
    })
  );

  // Step 2: Start device authorization
  const deviceAuth = await oidcClient.send(
    new StartDeviceAuthorizationCommand({
      clientId,
      clientSecret,
      startUrl: START_URL
    })
  );

  const loginUrl = deviceAuth.verificationUriComplete;

  // Step 3: Display clickable URL
  console.log("\n🔐 Please log in using your browser:\n");
  console.log(`👉  \x1b[36m${loginUrl}\x1b[0m\n`); // Cyan colored URL
  console.log("If this is WSL, copy the link and open it in your Windows browser.\n");

  // Optionally copy to clipboard:
  // await clipboardy.write(loginUrl);
  // console.log("📋 URL copied to clipboard");

  // Step 4: Poll for token
  let token;
  while (!token) {
    try {
      const tokenRes = await oidcClient.send(
        new CreateTokenCommand({
          grantType: "urn:ietf:params:oauth:grant-type:device_code",
          deviceCode: deviceAuth.deviceCode,
          clientId,
          clientSecret
        })
      );
      token = tokenRes;
    } catch (e) {
      if (e.name === "AuthorizationPendingException") {
        await new Promise((r) => setTimeout(r, deviceAuth.interval * 1000));
      } else {
        throw e;
      }
    }
  }

  return token;
}
