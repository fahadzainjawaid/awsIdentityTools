//rename this file to config.mjs

export const REGION = 'us-east-1'; //change this to your identity centre    region
export const START_URL = 'https://youraws.identity.center.endpoint/start';

// Optional: restrict which roles or accounts to fetch
export const ALLOWED_ROLE_NAMES = ["AdministratorAccess", "PowerUserAccess"];
export const INCLUDE_ACCOUNTS = []; // Empty = all accounts


// OIDC configuration for Azure DevOps

export const oidcProviderUrl = 'https://vstoken.dev.azure.com/<your entra ID tenant ID>';
export const audience = 'api://AzureADTokenExchange';
export const thumbprint = '<certificate thumbprint from microsoft>'; // Microsoft cert

// Function to get role and policy names based on pipeline user
export const getRoleName = (pipelineUser) => `${pipelineUser}-OIDCRole`;
export const getPolicyName = (pipelineUser) => `${pipelineUser}-OIDCPolicy`;

// Default policy document for OIDC roles. Adjust this as needed. Remember to limit permissions to only what is necessary. sts:AssumeRole is required for OIDC roles.
//must be included in the policy document
export const defaultPolicyDocument = {
  Version: "2012-10-17",
  Statement: [
    {
      Effect: "Allow",
      Action: [
        "s3:ListBucket",
        "sts:AssumeRole",
      ],
      Resource: "*"
    }
  ]
};