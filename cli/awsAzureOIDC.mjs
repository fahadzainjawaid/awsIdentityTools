#!/usr/bin/env node

import { Command } from 'commander';
import { AzureOIDCSetup } from '../src/AzureOIDCSetup.mjs';
import { 
  oidcProviderUrl, 
  audience, 
  thumbprint,
  getRoleName,
  getPolicyName,
  defaultPolicyDocument
} from "./config.mjs";

const program = new Command();

program
  .name('aws-azure-oidc')
  .description('Manage OIDC setup for Azure DevOps and AWS integration')
  .version('1.0.0');

// Create command
program
  .command('create')
  .description('Create OIDC setup for Azure DevOps and AWS integration')
  .requiredOption('-o, --org <organization>', 'Azure DevOps organization name')
  .requiredOption('-p, --project <project>', 'Azure DevOps project name')
  .option('-u, --pipeline-user <user>', 'Pipeline user name', 'azPipelinesUser')
  .option('--pipeline <pipeline>', 'Specific pipeline name (optional, if not provided allows any pipeline in project)')
  .action(async (options) => {
    const { org, project, pipelineUser, pipeline } = options;
    
    const oidcSetup = new AzureOIDCSetup({
      oidcProviderUrl,
      audience,
      thumbprint,
      roleName: getRoleName(pipelineUser),
      policyName: getPolicyName(pipelineUser),
      organization: org,
      project,
      pipeline,
      pipelineUser,
      policyDocument: defaultPolicyDocument
    });

    try {
      await oidcSetup.execute();
    } catch (error) {
      console.error('❌ Setup failed:', error.message);
      process.exit(1);
    }
  });

// Delete command
program
  .command('delete')
  .description('Delete OIDC setup for a specific pipeline user')
  .requiredOption('-o, --org <organization>', 'Azure DevOps organization name')
  .requiredOption('-p, --project <project>', 'Azure DevOps project name')
  .option('-u, --pipeline-user <user>', 'Pipeline user name', 'azPipelinesUser')
  .option('--pipeline <pipeline>', 'Specific pipeline name (optional, if not provided allows any pipeline in project)')
  .option('-a, --all', 'Delete everything including the OIDC provider (use with caution)')
  .action(async (options) => {
    const { org, project, pipelineUser, pipeline, all } = options;
    
    if (all) {
      console.log('⚠️  WARNING: You are about to delete the OIDC provider. This will affect ALL pipeline users using this provider.');
    }
    
    const oidcSetup = new AzureOIDCSetup({
      oidcProviderUrl,
      audience,
      thumbprint,
      roleName: getRoleName(pipelineUser),
      policyName: getPolicyName(pipelineUser),
      organization: org,
      project,
      pipeline,
      pipelineUser,
      policyDocument: defaultPolicyDocument
    });

    try {
      await oidcSetup.delete(all);
    } catch (error) {
      console.error('❌ Deletion failed:', error.message);
      process.exit(1);
    }
  });

program.parse();
