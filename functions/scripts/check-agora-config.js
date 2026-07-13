const fs = require("node:fs");
const path = require("node:path");

function loadLocalEnv() {
  const envPath = path.join(__dirname, "..", ".env");
  if (!fs.existsSync(envPath)) return;

  const raw = fs.readFileSync(envPath, "utf8");
  for (const line of raw.split(/\r?\n/)) {
    const trimmed = line.trim();
    if (!trimmed || trimmed.startsWith("#")) continue;

    const separator = trimmed.indexOf("=");
    if (separator <= 0) continue;

    const key = trimmed.slice(0, separator).trim();
    let value = trimmed.slice(separator + 1).trim();

    if (
      (value.startsWith("\"") && value.endsWith("\"")) ||
      (value.startsWith("'") && value.endsWith("'"))
    ) {
      value = value.slice(1, -1);
    }

    if (!process.env[key]) {
      process.env[key] = value;
    }
  }
}

loadLocalEnv();

const {
  evaluateAgoraTokenConfig,
} = require("../src/shared");

const readiness = evaluateAgoraTokenConfig();

if (readiness.isReady) {
  console.log("Agora server config: READY");
  console.log("AGORA_APP_ID: present");
  console.log("AGORA_APP_CERTIFICATE: present");
  process.exit(0);
}

console.error("Agora server config: NOT READY");
console.error(`Missing/invalid: ${readiness.missingRequirements.join(", ")}`);
console.error("");
console.error("Set real values in the Firebase Functions runtime:");
console.error("- AGORA_APP_ID");
console.error("- AGORA_APP_CERTIFICATE");
console.error("");
console.error(
  "For local emulator/dev, copy functions/.env.example to functions/.env and replace the placeholders."
);
process.exit(1);
