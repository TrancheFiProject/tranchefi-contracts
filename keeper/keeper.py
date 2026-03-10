"""
TrancheFi Keeper Bot
====================
Runs two loops:
  1. settleEpoch() — weekly, with STRC price and borrow rate
  2. checkHealthFactor() — every 30 seconds, triggers emergency deleverage if needed

Requires:
  pip install web3 requests python-dotenv

Environment variables (.env):
  RPC_URL=https://arb1.arbitrum.io/rpc
  PRIVATE_KEY=0x...
  VAULT_ADDRESS=0x...
  DERIBIT_API=https://www.deribit.com/api/v2
"""

import os
import sys
import time
import json
import logging
from decimal import Decimal

import requests
from web3 import Web3
from dotenv import load_dotenv

load_dotenv()

# ================================================================
# CONFIG
# ================================================================

RPC_URL = os.getenv("RPC_URL", "https://arb1.arbitrum.io/rpc")
PRIVATE_KEY = os.getenv("PRIVATE_KEY")
VAULT_ADDRESS = os.getenv("VAULT_ADDRESS")

EPOCH_INTERVAL = 7 * 24 * 60 * 60  # 7 days in seconds
HF_CHECK_INTERVAL = 30              # 30 seconds
STRC_PAR = 100.0

# API endpoints
YAHOO_STRC = "https://query1.finance.yahoo.com/v8/finance/chart/STRC?range=1d&interval=1m"

# ================================================================
# LOGGING
# ================================================================

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    handlers=[
        logging.StreamHandler(sys.stdout),
        logging.FileHandler("keeper.log"),
    ],
)
log = logging.getLogger("keeper")

# ================================================================
# WEB3 SETUP
# ================================================================

w3 = Web3(Web3.HTTPProvider(RPC_URL))

# Minimal ABI for keeper functions
VAULT_ABI = json.loads("""[
    {"inputs":[{"components":[
        {"name":"borrowRate","type":"uint256"},
        {"name":"strcPrice","type":"uint256"},
        {"name":"prevStrcPrice","type":"uint256"}
    ],"name":"signals","type":"tuple"}],
    "name":"settleEpoch","outputs":[],"stateMutability":"nonpayable","type":"function"},
    {"inputs":[],"name":"checkHealthFactor","outputs":[],"stateMutability":"nonpayable","type":"function"},
    {"inputs":[],"name":"canSettle","outputs":[{"name":"","type":"bool"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"getHealthFactor","outputs":[{"name":"","type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"getBorrowRate","outputs":[{"name":"","type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"currentEpoch","outputs":[{"name":"","type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"currentLeverage","outputs":[{"name":"","type":"uint256"}],"stateMutability":"view","type":"function"},
    {"inputs":[],"name":"isShutdown","outputs":[{"name":"","type":"bool"}],"stateMutability":"view","type":"function"}
]""")

# ================================================================
# ORACLE DATA FETCHING
# ================================================================

def fetch_btc_price():
    """Fetch BTC/USD from CoinGecko."""
    try:
        r = requests.get(COINGECKO_BTC, timeout=10)
        return r.json()["bitcoin"]["usd"]
    except Exception as e:
        log.warning(f"CoinGecko BTC fetch failed: {e}")
        return None


def fetch_strc_price():
    """Fetch STRC price from Yahoo Finance."""
    try:
        r = requests.get(YAHOO_STRC, headers={"User-Agent": "Mozilla/5.0"}, timeout=10)
        return r.json()["chart"]["result"][0]["meta"]["regularMarketPrice"]
    except Exception as e:
        log.warning(f"Yahoo STRC fetch failed: {e}")
        return None



# ================================================================
# SIGNAL CONSTRUCTION
# ================================================================

WAD = 10**18

def to_wad(value):
    """Convert float percentage to WAD (e.g. 25.0 -> 25e18)."""
    return int(Decimal(str(value)) * Decimal(str(WAD)))


def to_price8(value):
    """Convert float price to 8 decimals (e.g. 99.50 -> 9950000000)."""
    return int(Decimal(str(value)) * Decimal("1e8"))


def build_signal_data(strc_price, prev_strc_price, borrow_rate_wad):
    """Build SignalData struct for settleEpoch. Fixed leverage — no signal inputs."""
    return {
        "borrowRate": borrow_rate_wad,
        "strcPrice": to_price8(strc_price),
        "prevStrcPrice": to_price8(prev_strc_price),
    }


# ================================================================
# TRANSACTION HELPERS
# ================================================================

def send_tx(func):
    """Build, sign, and send a transaction. Returns receipt."""
    account = w3.eth.account.from_key(PRIVATE_KEY)
    nonce = w3.eth.get_transaction_count(account.address)

    tx = func.build_transaction({
        "from": account.address,
        "nonce": nonce,
        "gas": 2_000_000,
        "maxFeePerGas": w3.eth.gas_price * 2,
        "maxPriorityFeePerGas": w3.to_wei(0.1, "gwei"),
    })

    signed = account.sign_transaction(tx)
    tx_hash = w3.eth.send_raw_transaction(signed.raw_transaction)
    receipt = w3.eth.wait_for_transaction_receipt(tx_hash, timeout=120)

    return receipt


# ================================================================
# MAIN LOOPS
# ================================================================

def run_epoch_settlement(vault, state):
    """Check if epoch can settle, fetch signals, execute."""
    if not vault.functions.canSettle().call():
        return state

    log.info("=== EPOCH SETTLEMENT ===")

    # Fetch market data
    btc_price = fetch_btc_price()
    strc_price = fetch_strc_price()

    if not btc_price or not strc_price:
        log.error("Missing price data, skipping epoch")
        return state

    # Get borrow rate from adapter
    try:
        borrow_rate = vault.functions.getBorrowRate().call()
    except:
        borrow_rate = to_wad(5.5)  # fallback 5.5%

    # Build signals
    signals = build_signal_data(
        btc_price=btc_price,
        prev_btc_price=state.get("prev_btc", btc_price),
        strc_price=strc_price,
        prev_strc_price=state.get("prev_strc", strc_price),
        borrow_rate_wad=borrow_rate,
    )

    log.info(f"BTC: ${btc_price:,.0f} | STRC: ${strc_price:.2f} | Fixed 1.75x")
    log.info(f"Signals: borrow={signals['borrowRate']/WAD:.2f}%")

    # Execute
    try:
        func = vault.functions.settleEpoch(tuple(signals.values()))
        receipt = send_tx(func)
        epoch = vault.functions.currentEpoch().call()
        leverage = vault.functions.currentLeverage().call()
        hf = vault.functions.getHealthFactor().call()

        log.info(f"Epoch {epoch} settled | tx: {receipt.transactionHash.hex()}")
        log.info(f"  Leverage: {leverage/WAD:.2f}x | HF: {hf/WAD:.2f}")
        log.info(f"  Gas used: {receipt.gasUsed}")

    except Exception as e:
        log.error(f"settleEpoch failed: {e}")

    # Update state
    state["prev_btc"] = btc_price
    state["prev_strc"] = strc_price
    return state


def run_hf_check(vault):
    """Check health factor and trigger deleverage if needed."""
    try:
        hf = vault.functions.getHealthFactor().call()
        hf_float = hf / WAD

        if hf_float < 1.8:
            log.warning(f"HF LOW: {hf_float:.2f} — triggering checkHealthFactor()")
            func = vault.functions.checkHealthFactor()
            receipt = send_tx(func)
            log.warning(f"  HF check tx: {receipt.transactionHash.hex()} | gas: {receipt.gasUsed}")
        else:
            # Log every 10 minutes instead of every 30s
            if int(time.time()) % 600 < HF_CHECK_INTERVAL:
                log.info(f"HF check: {hf_float:.2f} (normal)")

    except Exception as e:
        log.error(f"HF check failed: {e}")


def main():
    if not PRIVATE_KEY:
        log.error("PRIVATE_KEY not set in .env")
        sys.exit(1)
    if not VAULT_ADDRESS:
        log.error("VAULT_ADDRESS not set in .env")
        sys.exit(1)

    vault = w3.eth.contract(address=VAULT_ADDRESS, abi=VAULT_ABI)
    account = w3.eth.account.from_key(PRIVATE_KEY)

    log.info("=" * 60)
    log.info("TrancheFi Keeper Bot Starting")
    log.info(f"  Vault: {VAULT_ADDRESS}")
    log.info(f"  Keeper: {account.address}")
    log.info(f"  Chain: {w3.eth.chain_id}")
    log.info(f"  Epoch interval: {EPOCH_INTERVAL}s | HF check: {HF_CHECK_INTERVAL}s")
    log.info("=" * 60)

    state = {}
    last_hf_check = 0

    while True:
        try:
            # Check if vault is shutdown
            if vault.functions.isShutdown().call():
                log.error("VAULT IS SHUTDOWN — keeper stopping")
                break

            # HF check every 30 seconds
            now = time.time()
            if now - last_hf_check >= HF_CHECK_INTERVAL:
                run_hf_check(vault)
                last_hf_check = now

            # Epoch settlement check every minute
            state = run_epoch_settlement(vault, state)

            time.sleep(10)  # Main loop tick

        except KeyboardInterrupt:
            log.info("Keeper stopped by user")
            break
        except Exception as e:
            log.error(f"Main loop error: {e}")
            time.sleep(30)


if __name__ == "__main__":
    main()
