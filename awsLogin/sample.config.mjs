//rename this file to config.mjs

export const REGION = 'us-east-1'; //change this to your identity centre    region
export const START_URL = 'https://youraws.identity.center.endpoint/start';

// Optional: restrict which roles or accounts to fetch
export const ALLOWED_ROLE_NAMES = ["AdministratorAccess", "PowerUserAccess"];
export const INCLUDE_ACCOUNTS = []; // Empty = all accounts
