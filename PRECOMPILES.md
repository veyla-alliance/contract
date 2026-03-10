# Polkadot Hub Precompiles — Research Notes
> Passet Hub Testnet (Chain ID: 420420417)
> Diperbarui: 10 Maret 2026

---

## Ringkasan Penting

Passet Hub menggunakan **pallet-revive (PolkaVM/REVM)** — BUKAN Frontier/pallet-evm seperti Moonbeam atau Astar.
Precompile set-nya berbeda. Jangan copy-paste dari Moonbeam docs.

---

## Precompile yang Tersedia

### 1. XCM Precompile ← PALING PENTING untuk Veyla
**Address:** `0x00000000000000000000000000000000000a0000`

```solidity
interface IXcm {
    struct Weight { uint64 refTime; uint64 proofSize; }

    function execute(bytes calldata message, Weight calldata weight) external;
    function send(bytes calldata destination, bytes calldata message) external;
    function weighMessage(bytes calldata message) external view returns (Weight memory);
}
```

**Cara pakai:**
```solidity
IXcm constant XCM = IXcm(0x00000000000000000000000000000000000a0000);

// Estimate weight dulu
IXcm.Weight memory w = XCM.weighMessage(xcmMessage);

// Execute locally
XCM.execute(xcmMessage, w);

// ATAU send cross-chain
XCM.send(destination, xcmMessage);
```

**Contoh encoded XCM message** (WithdrawAsset + BuyExecution + DepositAsset):
```
0x050c000401000003008c86471301000003008c8647000d010101000000010100368e8759...
```

---

### 2. Native Asset ERC-20 Precompile
**Address formula:** `0x[assetId 8hex][24 zeros][01200000]`

| Asset | Asset ID | Precompile Address |
|-------|----------|-------------------|
| USDT | 1984 (0x7C0) | `0x000007C000000000000000000000000001200000` |

```solidity
interface IERC20Precompile {
    function totalSupply() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function allowance(address owner, address spender) external view returns (uint256);
    function transfer(address to, uint256 amount) external returns (bool);
    function approve(address spender, uint256 amount) external returns (bool);
    function transferFrom(address from, address to, uint256 amount) external returns (bool);
}
```

**CATATAN KRITIS:** `name()`, `symbol()`, `decimals()` **TIDAK ada** di interface ini.
Harus baca via Substrate RPC atau hardcode di contract.

---

### 3. System Precompile
**Address:** `0x0000000000000000000000000000000000000900`

Utilities: Blake hash, account ID conversion, sr25519 verify, dll.
Tidak terlalu relevan untuk Veyla tapi berguna untuk debugging.

---

### 4. Standard Ethereum Precompiles
`0x01`–`0x09` — sama persis seperti Ethereum (ECRecover, SHA256, dll).

---

## Masalah DOT (Native Asset) ← PENTING

**DOT TIDAK punya ERC-20 precompile resmi di Passet Hub.**

| Cara | Status |
|------|--------|
| DOT via `msg.value` | ✅ Bisa |
| DOT via XCM instruction | ✅ Bisa |
| DOT via ERC-20 precompile | ❌ Belum ada |
| WDOT community contract (mainnet) | `0xaf905e66038EcE89e03D843B35a11D262053B630` — mainnet only |

### Implikasi untuk Veyla Contract:
- **USDT** → bisa pakai ERC-20 precompile langsung
- **DOT** → harus diterima via `msg.value` (native), lalu di-wrap internal di contract
- Atau fokus ke **USDT saja** untuk MVP hackathon

---

## Rekomendasi Arsitektur Contract (berdasarkan research ini)

### Option A — USDT Only (Paling Simpel, Paling Aman)
- Vault hanya terima USDT via ERC-20 precompile
- XCM routing untuk demo: kirim USDT ke parachain lain
- DOT support bisa ditambah setelah hackathon

### Option B — DOT via msg.value + USDT via ERC-20
- Vault terima DOT via `payable` + `msg.value`
- Vault terima USDT via ERC-20 precompile
- Lebih komplex tapi lebih lengkap secara fitur

**Untuk hackathon: Option A dulu, lebih fokus dan lebih sedikit bug risiko.**

---

## Link Referensi

- [XCM Precompile Docs](https://docs.polkadot.com/develop/smart-contracts/precompiles/xcm-precompile/)
- [ERC20 Precompile Docs](https://docs.polkadot.com/smart-contracts/precompiles/erc20/)
- [System Precompile Docs](https://docs.polkadot.com/smart-contracts/precompiles/system/)
- [All Precompiles Overview](https://docs.polkadot.com/smart-contracts/precompiles/)
- [PolkaVM Hardhat Examples](https://github.com/polkadot-developers/polkavm-hardhat-examples)
- [polkadot-sdk source (IXcm.sol)](https://github.com/paritytech/polkadot-sdk)
