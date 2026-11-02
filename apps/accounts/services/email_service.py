"""
Reexportação de BrevoEmailService para retrocompatibilidade de namespace.
"""
from apps.accounts.brevo_service import BrevoEmailService

__all__ = ["BrevoEmailService"]
