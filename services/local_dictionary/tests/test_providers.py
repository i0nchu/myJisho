from __future__ import annotations

import os
import unittest
from unittest.mock import patch

from services.local_dictionary.providers import (
    LLMConfigurationError,
    OpenAICompatibleLLMProvider,
)


class LLMProviderConfigurationTests(unittest.TestCase):
    def test_model_is_required_when_argument_and_environment_are_missing(self) -> None:
        with patch.dict(os.environ, {}, clear=True):
            with self.assertRaisesRegex(
                LLMConfigurationError,
                "MYJISHO_LLM_MODEL is required",
            ):
                OpenAICompatibleLLMProvider()

    def test_blank_model_is_rejected(self) -> None:
        with patch.dict(
            os.environ,
            {"MYJISHO_LLM_MODEL": "   "},
            clear=True,
        ):
            with self.assertRaises(LLMConfigurationError):
                OpenAICompatibleLLMProvider()

    def test_environment_model_is_loaded_without_a_default(self) -> None:
        with patch.dict(
            os.environ,
            {"MYJISHO_LLM_MODEL": "custom-model:latest"},
            clear=True,
        ):
            provider = OpenAICompatibleLLMProvider()

        self.assertEqual(provider.model, "custom-model:latest")

    def test_explicit_model_takes_precedence_and_is_trimmed(self) -> None:
        with patch.dict(
            os.environ,
            {"MYJISHO_LLM_MODEL": "environment-model"},
            clear=True,
        ):
            provider = OpenAICompatibleLLMProvider(model=" explicit-model ")

        self.assertEqual(provider.model, "explicit-model")


if __name__ == "__main__":
    unittest.main()
