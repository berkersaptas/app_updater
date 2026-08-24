import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
import Ajv2020 from 'ajv/dist/2020.js';

const __dirname = path.dirname(fileURLToPath(import.meta.url));

// Single source of truth: the same schema ota_runtime_android and scripts/validate_json_schema.py
// validate against, read directly rather than duplicated here.
const schemaPath = path.join(__dirname, '..', '..', 'ota_core', 'manifest.schema.json');
const schema = JSON.parse(readFileSync(schemaPath, 'utf8'));

const ajv = new Ajv2020({ allErrors: true, strict: false });
const validateManifestSchema = ajv.compile(schema);

export function validateManifest(manifest) {
  const valid = validateManifestSchema(manifest);
  if (valid) return { valid: true, errors: [] };
  return {
    valid: false,
    errors: validateManifestSchema.errors.map((e) => `${e.instancePath || '(root)'} ${e.message}`),
  };
}
