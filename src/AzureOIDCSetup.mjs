#!/usr/bin/env node

import { execSync } from 'child_process';

export class AzureOIDCSetup {
  constructor({
    oidcProviderUrl,
    audience,
    thumbprint,
    roleName,
    policyName,
    organization,
    project = null,
    pipeline = null,
    pipelineUser = 'azPipelinesUser',
    policyDocument
  }) {
    this.oidcProviderUrl = oidcProviderUrl;
    this.audience = audience;
    this.thumbprint = thumbprint;
    this.roleName = roleName;
    this.policyName = policyName;
    this.organization = organization;
    this.project = project;
    this.pipeline = pipeline;
    this.pipelineUser = pipelineUser;
    this.policyDocument = policyDocument;
  }

  async execute() {
    console.log(`\n🔧 Creating OIDC setup for pipeline user: ${this.pipelineUser}\n`);
    try {
      await this._createOIDCProvider();
      const providerArn = await this._getProviderArn();
      await this._createIAMRole(providerArn);
      await this._attachPolicy();
      this._outputConfiguration();
    } catch (error) {
      console.error('❌ Error during setup:', error.message);
      throw error;
    }
  }

  async delete(deleteProvider = false) {
    console.log(`\n🗑️ Deleting OIDC setup for pipeline user: ${this.pipelineUser}\n`);
    try {
      await this._deleteRolePolicy();
      await this._deleteIAMRole();
      if (deleteProvider) {
        await this._deleteOIDCProvider();
      }
      console.log(`\n✅ OIDC setup for ${this.pipelineUser} has been deleted successfully.`);
    } catch (error) {
      console.error('❌ Error during deletion:', error.message);
      throw error;
    }
  }

  async _createOIDCProvider() {
    const createProviderCommand = `
      aws iam create-open-id-connect-provider \
        --url ${this.oidcProviderUrl} \
        --client-id-list ${this.audience} \
        --thumbprint-list ${this.thumbprint}
    `;
    try {
      execSync(createProviderCommand, { stdio: 'pipe' });
      console.log('✅ OIDC Provider created.');
    } catch (error) {
      const msg = (error.stderr?.toString() || error.message || '').trim();
      // Reusing an existing provider is fine; anything else is a real failure
      // and must surface rather than be silently swallowed.
      if (msg.includes('EntityAlreadyExists')) {
        console.log('ℹ️ OIDC Provider already exists, reusing it.');
      } else {
        throw new Error(`Failed to create OIDC provider: ${msg}`);
      }
    }
  }

  async _getProviderArn() {
    // `--output text` separates multiple ARNs with tabs (and/or newlines),
    // so split on any whitespace rather than just '\n'.
    const providerList = execSync(`aws iam list-open-id-connect-providers --query 'OpenIDConnectProviderList[*].Arn' --output text`)
      .toString()
      .trim()
      .split(/\s+/)
      .filter(Boolean);
    const normalizedUrl = this.oidcProviderUrl.replace(/^https:\/\//, '');
    // Match the provider whose URL is exactly this one. A previous `endsWith`
    // check matched everything when normalizedUrl was empty, silently picking
    // the wrong provider.
    const providerArn = providerList.find(arn => arn.split(':oidc-provider/')[1] === normalizedUrl);
    if (!providerArn) throw new Error(`OIDC Provider not found for URL: ${normalizedUrl}`);
    return providerArn;
  }

  async _createIAMRole(providerArn) {
    const trustPolicy = this._getTrustPolicy(providerArn);

    const createRoleCmd = `
      aws iam create-role \
        --role-name ${this.roleName} \
        --assume-role-policy-document '${JSON.stringify(trustPolicy)}'
    `;
    try {
      execSync(createRoleCmd, { stdio: 'ignore' });
      console.log('✅ IAM Role created.');
    } catch {
      console.log('ℹ️ IAM Role already exists or could not be created (might already exist).');
    }
  }

  _getTrustPolicy(providerArn) {
    let subClaim;
    
    if (this.project) {
      // Specific project
      subClaim = this.pipeline
        ? `sc://${this.organization}/${this.project}/${this.pipeline}`
        : `sc://${this.organization}/${this.project}/*`;
    } else {
      // Any project in organization
      subClaim = `sc://${this.organization}/*`;
    }

    // Extract the provider URL without https:// for condition keys
    const normalizedUrl = this.oidcProviderUrl.replace(/^https:\/\//, '');

    return {
      Version: "2012-10-17",
      Statement: [
        {
          Effect: "Allow",
          Principal: { Federated: providerArn },
          Action: "sts:AssumeRoleWithWebIdentity",
          Condition: {
            StringEquals: {
              [`${normalizedUrl}:aud`]: this.audience
            },
            StringLike: {
              [`${normalizedUrl}:sub`]: subClaim
            }
          }
        }
      ]
    };
  }

  async _attachPolicy() {
    const putPolicyCommand = `
      aws iam put-role-policy \
        --role-name ${this.roleName} \
        --policy-name ${this.policyName} \
        --policy-document '${JSON.stringify(this.policyDocument)}'
    `;

    execSync(putPolicyCommand);
    console.log('✅ Policy attached to the IAM Role.\n');
  }

  _outputConfiguration() {
    const accountId = execSync('aws sts get-caller-identity --query Account --output text').toString().trim();
    const roleArn = `arn:aws:iam::${accountId}:role/${this.roleName}`;

    console.log(`🔐 Use the following values in your Azure DevOps Service Connection:\n`);
    console.log(`▶️ OIDC Provider URL: ${this.oidcProviderUrl}`);
    console.log(`▶️ Audience:          ${this.audience}`);
    console.log(`▶️ Role ARN:          ${roleArn}`);
    console.log(`▶️ Thumbprint:        ${this.thumbprint}`);
    console.log(`▶️ Org:               ${this.organization}`);
    console.log(`▶️ Project:           ${this.project || '<any project in organization>'}`);
    console.log(`▶️ Pipeline:          ${this.pipeline || '<any pipeline in project>'}`);

    console.log(`\n✅ Setup complete.`);
    console.log(`\n▶️ Example Azure DevOps configuration:\n`);
    console.log(`▶️ Access ID: <leave blank>`);
    console.log(`▶️ Secret Access Key: <leave blank>`);
    console.log(`▶️ Session Token: <leave blank>`);
    console.log(`▶️ Role to Assume: ${roleArn}`);
    console.log(`▶️ Role Session Name: azdo-session`);
    console.log(`▶️ External ID: <leave blank>`);
    console.log(`▶️ Use OIDC: CHECKED`);
  }

  async _deleteRolePolicy() {
    const deleteCmd = `
      aws iam delete-role-policy \
        --role-name ${this.roleName} \
        --policy-name ${this.policyName}
    `;
    try {
      execSync(deleteCmd, { stdio: 'ignore' });
      console.log('✅ Role policy deleted.');
    } catch {
      console.log('ℹ️ Role policy does not exist or could not be deleted.');
    }
  }

  async _deleteIAMRole() {
    const deleteCmd = `aws iam delete-role --role-name ${this.roleName}`;
    try {
      execSync(deleteCmd, { stdio: 'ignore' });
      console.log('✅ IAM Role deleted.');
    } catch {
      console.log('ℹ️ IAM Role does not exist or could not be deleted.');
    }
  }

  async _deleteOIDCProvider() {
    try {
      const providerArn = await this._getProviderArn();
      execSync(`aws iam delete-open-id-connect-provider --open-id-connect-provider-arn ${providerArn}`, {
        stdio: 'ignore'
      });
      console.log('✅ OIDC Provider deleted.');
    } catch {
      console.log('ℹ️ OIDC Provider does not exist or could not be deleted.');
    }
  }
}
