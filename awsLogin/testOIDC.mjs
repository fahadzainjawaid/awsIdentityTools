import { SSOOIDCClient, RegisterClientCommand } from "@aws-sdk/client-sso-oidc";

const REGION = "us-west-2"; // Replace with your Identity Center region

async function testClient() {
  const client = new SSOOIDCClient({ region: REGION });

  const registerCommand = new RegisterClientCommand({
    clientName: "aws-sso-test",
    clientType: "public",
    scopes: ["sso:account:access"]
  });

  const response = await client.send(registerCommand);
  console.log("✅ Registered client:", response);
}

testClient().catch(console.error);
