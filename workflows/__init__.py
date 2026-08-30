"""Named, resumable auto-labeling workflows."""

from .bootstrap_new_classes import bootstrap_new_classes
from .improve_offboard_model import improve_offboard_model

WORKFLOWS = {
    "bootstrap_new_classes": bootstrap_new_classes,
    "improve_offboard_model": improve_offboard_model,
}

__all__ = ["WORKFLOWS", "bootstrap_new_classes", "improve_offboard_model"]
