#!/usr/bin/env node
/**
 * backup-mainnet-addresses.js
 *
 * Copies mainnet-addresses.ts to mainnet.backup.<timestamp>.ts
 * so that multiple runs between commits each produce a snapshot.
 */

const fs = require('fs');
const path = require('path');

const ADDRESSES_FILE = path.join(__dirname, '..', 'server', 'deployments', 'mainnet-addresses.ts');

const now = new Date();
const stamp = now.toISOString().replace(/[:.]/g, '-').replace('T', '_').replace('Z', '');
const backupFile = path.join(__dirname, '..', 'server', 'deployments', `mainnet.backup.${stamp}.ts`);

fs.copyFileSync(ADDRESSES_FILE, backupFile);
console.log(`Backup: ${path.basename(backupFile)}`);
