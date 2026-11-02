"""
Re-exportação da classe de serviço OrderStateMachineManager e exceções associadas.
Permite importar diretamente a partir de `apps.orders.state_machine_manager`.
"""
from apps.orders.state_machine import (
    InvalidStateTransition,
    InvalidStateTransitionError,
    OrderNotFoundError,
    OrderStateMachine,
    OrderStateMachineError,
    OrderStateMachineManager,
    OrderTransitionResult,
)

__all__ = [
    "OrderStateMachineManager",
    "OrderStateMachine",
    "InvalidStateTransition",
    "InvalidStateTransitionError",
    "OrderNotFoundError",
    "OrderStateMachineError",
    "OrderTransitionResult",
]

