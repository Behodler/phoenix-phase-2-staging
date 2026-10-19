/**
 * The `ContractAddresses` interface key set, shared by extract-addresses.js (zero-address
 * placeholders, story 104) and generate-ts-addresses.js (the non-anvil key-set check, story 098).
 *
 * `deployments/addresses.ts` is generated from chain 31337 only; every other chain types against
 * it and must match its key set exactly.
 */

const fs = require('fs');
const path = require('path');

const DEFAULT_INTERFACE_PATH = path.join(__dirname, 'deployments', 'addresses.ts');

/**
 * Parses the key set of `export interface ContractAddresses { ... }` from TypeScript source.
 * Throws if the block is missing or empty.
 */
function parseInterfaceKeys(source, label = 'addresses.ts') {
    const block = source.match(/export interface ContractAddresses\s*\{([\s\S]*?)\n\}/);
    if (!block) {
        throw new Error(`no 'export interface ContractAddresses { ... }' block in ${label}`);
    }
    const keys = [];
    for (const line of block[1].split('\n')) {
        const m = line.match(/^\s*([A-Za-z_$][A-Za-z0-9_$]*)\s*:\s*string\s*;/);
        if (m) keys.push(m[1]);
    }
    if (keys.length === 0) {
        throw new Error(`ContractAddresses in ${label} has no keys`);
    }
    return keys;
}

/**
 * Reads the interface key set from `addresses.ts` (or `interfacePath`). Throws if the file is
 * missing or has no interface block.
 */
function readInterfaceKeysFromFile(interfacePath = DEFAULT_INTERFACE_PATH) {
    if (!fs.existsSync(interfacePath)) {
        throw new Error(`interface file not found: ${interfacePath}`);
    }
    return parseInterfaceKeys(fs.readFileSync(interfacePath, 'utf-8'), interfacePath);
}

/**
 * The difference between an extracted key set and the interface key set.
 * @returns {{missing: string[], extra: string[]}}
 */
function diffKeySet(contractNames, interfaceKeys) {
    const have = new Set(contractNames);
    const want = new Set(interfaceKeys);
    return {
        missing: interfaceKeys.filter((k) => !have.has(k)),
        extra: contractNames.filter((k) => !want.has(k)),
    };
}

module.exports = {
    DEFAULT_INTERFACE_PATH,
    parseInterfaceKeys,
    readInterfaceKeysFromFile,
    diffKeySet,
};
