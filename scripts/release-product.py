"""The two supported, fixed app identities. No caller-provided bundle IDs or servers."""
import os

PRODUCTS = {
    "onlyx": {"scheme": "OnlyXLogin", "bundle": "ai.onlyx.login", "name": "OnlyX Login", "url_scheme": "onlyx-connect"},
    "white-label": {"scheme": "WhiteLabelLogin", "bundle": "ai.onlyx.whitelabel.login", "name": "Login", "url_scheme": "secure-connect"},
}
product = os.environ.get("LOGIN_PRODUCT", "onlyx")
if product not in PRODUCTS:
    raise ValueError("LOGIN_PRODUCT must be onlyx or white-label.")
PRODUCT = PRODUCTS[product]
