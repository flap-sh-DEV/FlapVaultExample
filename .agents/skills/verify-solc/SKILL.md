---
name: verify-solc
description: "Verify Solidity smart contracts against on-chain deployed bytecode. Use when: verifying a contract, checking if source matches deployment, comparing bytecode, detecting compiler version from deployed bytecode, fetching bytecode from contract address, running solc verification, checking partial match or metadata mismatch, diffing compiled vs deployed bytecode."
argument-hint: "<contract-address> or <rpc-url>"
---

# verify-solc Skill

Verify that the Solidity source in `input.json` matches a deployed contract on-chain — or against a locally-saved bytecode file.

## Scripts

| Script | Purpose |
|---|---|
| [verify_address.js](verify_address.js) | Fetch bytecode from chain by address, auto-detect compiler version, compile & compare |
| [verify.js](verify.js) | Compile `input.json` and compare against `deployed_bytecode.txt` |
| [analyze_diff.js](analyze_diff.js) | Deep byte-level diff between compiled and deployed bytecode |
| [verify_source.js](verify_source.js) | Verify that a flattened `.sol` file matches the sources in `input.json` |

---

## Workflows

### 1. Verify by contract address (recommended)

Requires only a contract address and an RPC endpoint. The script automatically detects the exact compiler version from the bytecode's CBOR metadata.

```bash
# Default — uses BNB Chain public RPC automatically (no flag needed)
node verify_address.js 0xYourContractAddress

# Override RPC if needed
node verify_address.js 0xYourContractAddress --rpc https://bsc-dataseed1.defibit.io/

# Or via env var
ETH_RPC_URL=https://custom-rpc.example.com node verify_address.js 0xYourContractAddress
```

> Default RPC: `https://bsc-dataseed.binance.org/` (BNB Chain mainnet)

**Steps performed automatically:**
1. `eth_getCode` → fetches deployed bytecode
2. CBOR metadata parse → detects `solc` version (e.g. `0.8.24`)
3. Downloads that exact solc binary from `binaries.soliditylang.org`
4. Compiles `input.json` with that version
5. Reports Exact Match / Partial Match / Mismatch

### 2. Verify against a saved bytecode file

Put the deployed bytecode (hex, with or without `0x` prefix) into `deployed_bytecode.txt`, then:

```bash
# Defaults: --input input.json  --bytecode deployed_bytecode.txt
node verify.js

# Custom input file
node verify.js --input x.json

# Custom bytecode file
node verify.js --bytecode other_bytecode.txt

# Both overridden
node verify.js --input x.json --bytecode other_bytecode.txt
```

### Parameters

| Flag | Default | Description |
|---|---|---|
| `--input` | `input.json` | Path to the Standard JSON input file |
| `--bytecode` | `deployed_bytecode.txt` | Path to the deployed bytecode file |

### 3. Deep diff analysis

When you get a Mismatch or Partial Match, run the diff script to pinpoint exactly which bytes differ:

```bash
node analyze_diff.js
```

### 4. Verify a flattened source file

Check that a flattened `.sol` file is consistent with the sources embedded in `input.json`:

```bash
node verify_source.js path/to/Flattened.sol
```

---

## Match Results

| Output | Meaning |
|---|---|
| `Exact Match` | Deployed bytecode is byte-for-byte identical to compiled output |
| `Partial Match (metadata hash mismatch likely)` | Executable logic matches; only the CBOR metadata hash differs (different compiler settings, build environment, or IPFS hash) |
| `Mismatch` | Source does not correspond to the deployed contract |

---

## Compiler Version Handling

`verify_address.js` handles version mismatches automatically via the CBOR metadata embedded at the end of every `>=0.4.7` Solidity deployment. If the on-chain version differs from the locally installed `solc`, the correct binary is fetched from `binaries.soliditylang.org` at runtime.

For contracts compiled before CBOR metadata was available (pre-0.4.7) or non-Solidity contracts, use `verify.js` and manually ensure the right compiler is installed.

---

## Prerequisites

```bash
npm install        # installs solc
```

`verify_address.js` defaults to BNB Chain (`https://bsc-dataseed.binance.org/`). Override with `--rpc <url>` or `ETH_RPC_URL` env var.
