import { Command } from "commander";
import fs from "fs";
import ini from "ini";
import inquirer from "inquirer";
import os from "os";
import path from "path";

const program = new Command();
const credentialsPath = path.join(os.homedir(), ".aws", "credentials");
const backupPath = path.join(os.homedir(), ".aws", "credentials.bak");

program
  .option("-p, --profile <profile>", "Profile to set as default")
  .parse(process.argv);

const options = program.opts();

if (!options.profile) {
  console.error("Please provide a profile name using --profile option.");
  process.exit(1);
}

const profileToSet = options.profile;

function readCredentials() {
  if (!fs.existsSync(credentialsPath)) {
    console.error("AWS credentials file not found.");
    process.exit(1);
  }
  return ini.parse(fs.readFileSync(credentialsPath, "utf-8"));
}

function writeCredentials(credentials) {
  fs.writeFileSync(credentialsPath, ini.stringify(credentials));
}

function backupCredentials() {
  fs.copyFileSync(credentialsPath, backupPath);
}

async function updateCredentials() {
  const credentials = readCredentials();
  backupCredentials();

  console.log("Current profiles:");
  console.log(credentials);

  let currentDefaultProfile = credentials.default;

  if (currentDefaultProfile) { 
    if (!currentDefaultProfile.profile_name) {
      const answers = await inquirer.prompt([
        {
          type: "input",
          name: "profile_name",
          message: "Enter the name of the current default profile:"
        }
      ]);
      currentDefaultProfile.profile_name = answers.profile_name;
    }
  }

  let currentDefaultProfileName = null;
  if (currentDefaultProfile) {
    currentDefaultProfileName = currentDefaultProfile.profile_name;
    credentials[currentDefaultProfileName] = { ...currentDefaultProfile };
  } else {
    console.warn("No current default profile found. Setting new profile as default.");
    credentials.default = {};
    credentials.default.profile_name = profileToSet;
  }

  for (const profile in credentials) {
    if (profile !== "default" && !credentials[profile].profile_name) {
      credentials[profile].profile_name = profile;
    }
  }

  credentials.default = credentials[profileToSet];
  credentials.default.profile_name = profileToSet;

  writeCredentials(credentials);

  let last4AccessKeyId  = null;
  if (currentDefaultProfile) {
    last4AccessKeyId = currentDefaultProfile.aws_access_key_id.slice(-4);
    console.log(`Profile "${profileToSet}" has been set as the default profile.`);
    console.log(
      `The previous default profile "${currentDefaultProfileName}" was saved with access key ID ending in ${last4AccessKeyId}.`
    );
  } else {
    console.log(`Profile "${profileToSet}" has been set as the default profile.`);
  }
}

updateCredentials().catch((error) => {
  console.error("An error occurred:", error);
  process.exit(1);
});
