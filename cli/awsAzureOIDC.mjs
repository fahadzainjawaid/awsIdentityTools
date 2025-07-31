#!/usr/bin/env node

import { execSync } from 'child_process';
import { argv } from 'process';

import { oidcProviderUrl, 
audience, 
thumbprint,
roleName,
policyName } from "./config.mjs";


// 1. Parse CLI Arguments
const pipelineUserArgIndex = argv.indexOf('--pipeline-user');
const pipelineUser =
  pipelineUserArgIndex !== -1 && argv[pipelineUserArgIndex + 1]
    ? argv[pipelineUserArgIndex + 1]
    : 'azPipelinesUser';

console.log(`\n🔧 Creating OIDC setup for pipeline user: ${pipelineUser}\n`);


try {
  // 3. Create OIDC Provider if it doesn't exist
  const createProviderCommand = `
    aws iam create-open-id-connect-provider \
      --url ${oidcProviderUrl} \
      --client-id-list ${audience} \
      --thumbprint-list ${thumbprint}
  `;

  try {
    execSync(createProviderCommand, { stdio: 'ignore' });
    console.log('✅ OIDC Provider created.');
  } catch {
    console.log('ℹ️ OIDC Provider already exists or could not be created (might already be configured).');
  }

  // 4. Get OIDC Provider ARN
  const getProviderArnCommand = `aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[*].Arn' --output text`;
  const providerList = execSync(getProviderArnCommand).toString().trim().split('\n');
  const providerArn = providerList.find(arn => arn.includes('pipelines.azure.com'));

  if (!providerArn) throw new Error('OIDC Provider not found.');

  // 5. Create IAM Trust Policy
  const trustPolicy = {
    Version: "2012-10-17",
    Statement: [
      {
        Effect: "Allow",
        Principal: {
          Federated: providerArn
        },
        Action: "sts:AssumeRoleWithWebIdentity",
        Condition: {
          StringEquals: {
            "pipelines.azure.com:aud": audience
          }
        }
      }
    ]
  };

  // 6. Create Role
  const roleCreateCommand = `
    aws iam create-role \
      --role-name ${roleName} \
      --assume-role-policy-document '${JSON.stringify(trustPolicy)}'
  `;

  try {
    execSync(roleCreateCommand, { stdio: 'ignore' });
    console.log('✅ IAM Role created.');
  } catch {
    console.log('ℹ️ IAM Role already exists or could not be created (might already exist).');
  }

  // 7. Attach Basic Policy (you may need to modify based on use case)
  const policyDocument = {
    Version: "2012-10-17",
    Statement: [
      {
        Effect: "Allow",
        Action: [
          "s3:ListBucket",
          "sts:AssumeRole"
        ],
        Resource: "*"
      }
    ]
  };

  const putPolicyCommand = `
    aws iam put-role-policy \
      --role-name ${roleName} \
      --policy-name ${policyName} \
      --policy-document '${JSON.stringify(policyDocument)}'
  `;

  execSync(putPolicyCommand);
  console.log('✅ Policy attached to the IAM Role.\n');

  // 8. Output Required Azure DevOps Config
  const roleArn = `arn:aws:iam::${execSync('aws sts get-caller-identity --query Account --output text').toString().trim()}:role/${roleName}`;

  console.log(`🔐 Use the following values in your Azure DevOps Service Connection:\n`);
  console.log(`▶️ OIDC Provider URL: ${oidcProviderUrl}`);
  console.log(`▶️ Audience:          ${audience}`);
  console.log(`▶️ Role ARN:          ${roleArn}`);
  console.log(`▶️ Thumbprint:        ${thumbprint}`);
  console.log(`\n✅ Setup complete.`);

} catch (error) {
  console.error('❌ Error during setup:', error.message);
  process.exit(1);
}
