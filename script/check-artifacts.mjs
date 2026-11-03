// Keeps the published artifacts honest:
// - the frozen v3.1 sources under v31/ are byte-for-byte the ones deployed;
// - every ABI under abi/ is what the sources in this repository compile to;
// - with MAINNET_RPC_URL set, the v3.1 build matches the code on Ethereum mainnet, immutables masked and metadata hash
//   included. The URL is read from the environment only, so it never appears in arguments or logs.
// Run through: npm run check:artifacts
import assert from 'node:assert/strict';
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const root = path.resolve(import.meta.dirname, '..');
const read = file => fs.readFileSync(path.join(root, file));
const json = file => JSON.parse(read(file));
const artifact = (base, file, name) => json(`${base}out/${file}/${name}.json`);

const FROZEN = {
  'v31/src/v3/ExpoGachaPool.sol': '5e5cf29bcfb2b1720b5e183c4ea47ca048e4a4a132e8e5d5155a40c7eca2dbc8',
  'v31/src/v3/ExpoLaunchpad.sol': '62e48b1fab4a60dd4c4d9bf7571de78d5fa525909c1b015ecd5510a947fd9733',
  'v31/src/ExpoPool.sol': '5d975a5c01fd10e7cedb6971b79c98ac9fc32dbb6a7260e2e749fda293f537c9',
  'v31/src/ExpoVault.sol': '9a29824df73f02a75bdca5b200ba7d2e5dfd523df0e5ffdc5c7e974ad8b30fea',
};
for (const [file, hash] of Object.entries(FROZEN)) {
  assert.equal(crypto.createHash('sha256').update(read(file)).digest('hex'), hash, `${file} was edited`);
}
console.log('Frozen v3.1 sources: unchanged.');

const ABIS = [
  ['ExpoGachaPool', 'v31/', 'ExpoGachaPool.sol', 'ExpoGachaPool'],
  ['ExpoLaunchpad', 'v31/', 'ExpoLaunchpad.sol', 'ExpoLaunchpad'],
  ['ExpoGachaPoolV32', '', 'ExpoGachaPool.sol', 'ExpoGachaPool'],
  ['ExpoLaunchpadV32', '', 'ExpoLaunchpad.sol', 'ExpoLaunchpad'],
  ['ExpoAdmissionRegistry', '', 'ExpoAdmissionRegistry.sol', 'ExpoAdmissionRegistry'],
  ['ExpoVault', '', 'ExpoVault.sol', 'ExpoVault'],
  ['ChainlinkRandomness', '', 'ChainlinkRandomness.sol', 'ChainlinkRandomness'],
];
for (const [exported, base, file, name] of ABIS) {
  assert.deepEqual(artifact(base, file, name).abi, json(`abi/${exported}.abi.json`), `abi/${exported}.abi.json is stale`);
}
console.log(`ABIs: ${ABIS.length} match the sources.`);

const rpc = process.env.MAINNET_RPC_URL;
if (!rpc) {
  console.log('MAINNET_RPC_URL not set: mainnet comparison skipped.');
} else {
  const deployment = json('deployments/mainnet-v3.1.json');
  const mask = (code, references) => {
    for (const list of Object.values(references)) {
      for (const { start, length } of list) {
        code = code.slice(0, start * 2) + '0'.repeat(length * 2) + code.slice((start + length) * 2);
      }
    }
    return code;
  };
  for (const [name, address] of [['ExpoGachaPool', deployment.pool], ['ExpoLaunchpad', deployment.launchpad]]) {
    const response = await fetch(rpc, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json' },
      body: JSON.stringify({ jsonrpc: '2.0', id: 1, method: 'eth_getCode', params: [address, 'latest'] }),
    });
    const { result } = await response.json();
    const { deployedBytecode: built } = artifact('v31/', `${name}.sol`, name);
    const references = built.immutableReferences;
    assert.equal(mask(result.slice(2), references), mask(built.object.slice(2), references), `${name} differs from the mainnet code`);
    console.log(`${name}: matches the mainnet code at ${address}.`);
  }
}
