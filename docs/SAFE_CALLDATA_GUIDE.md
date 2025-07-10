# Safe CallData Guide

## Install safe-cli

```bash
pip install --upgrade "safe-cli[ledger]"
```

## Run safe-cli

```bash
safe-cli 0x26c158A4CD56d148c554190A95A921d90F00C160 $RPC_URL
```

## Load Owner


Change the derivation path to the one you want to use.

```bash
load_ledger_cli_owners --derivation-path "44'/60'/1'/0/0"
```

## Enable Transaction Service

```bash
tx-service enable
```

## Send Transaction

0xA238CBeb142c10Ef7Ad8442C6D1f9E89e07e7761 is the safe Multisend contract address.

```bash
send_custom 0xA238CBeb142c10Ef7Ad8442C6D1f9E89e07e7761 0 $CALLDATA --delegate
```




