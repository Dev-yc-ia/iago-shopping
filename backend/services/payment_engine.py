from dataclasses import dataclass
from typing import Protocol


@dataclass(frozen=True)
class PaymentScenario:
    status: str
    label: str
    description: str


@dataclass(frozen=True)
class PaymentEngineMetadata:
    provider: str
    mode: str
    methods: list[str]
    future_provider: str
    webhook_ready: bool
    scenarios: list[PaymentScenario]
    mock_config: "MockPaymentConfig | None" = None
    public_key: str | None = None
    provider_mode: str | None = None
    poll_interval_ms: int = 3000


@dataclass(frozen=True)
class MockPaymentConfig:
    scenario: str = "sempre_aprovar"
    delay_ms: int = 3500
    timeout_ms: int = 9000
    expiration_ms: int = 300000


class PaymentProvider(Protocol):
    provider: str
    mode: str
    methods: list[str]
    future_provider: str
    webhook_ready: bool
    mock_config: MockPaymentConfig | None

    def scenarios(self) -> list[PaymentScenario]:
        ...

    def metadata(self) -> PaymentEngineMetadata:
        ...


class BasePaymentProvider:
    provider = "base"
    mode = "disabled"
    methods = ["pix", "cartao_debito", "cartao_credito"]
    future_provider = "mercado_pago"
    webhook_ready = False
    mock_config: MockPaymentConfig | None = None

    def scenarios(self) -> list[PaymentScenario]:
        return []

    def metadata(self) -> PaymentEngineMetadata:
        return PaymentEngineMetadata(
            provider=self.provider,
            mode=self.mode,
            methods=self.methods,
            future_provider=self.future_provider,
            webhook_ready=self.webhook_ready,
            scenarios=self.scenarios(),
            mock_config=self.mock_config,
        )


class MockPaymentProvider(BasePaymentProvider):
    provider = "mock"
    mode = "local_simulation"
    webhook_ready = True

    def __init__(self, config: MockPaymentConfig | None = None) -> None:
        self.mock_config = config or MockPaymentConfig()

    def scenarios(self) -> list[PaymentScenario]:
        return [
            PaymentScenario(
                status="aprovado",
                label="Sempre aprovar",
                description="Confirma o pagamento automaticamente e baixa estoque.",
            ),
            PaymentScenario(
                status="recusado",
                label="Sempre recusar",
                description="Recusa o pagamento automaticamente sem baixar estoque.",
            ),
            PaymentScenario(
                status="expirado",
                label="Expiração",
                description="Expira a tentativa de pagamento sem baixar estoque.",
            ),
            PaymentScenario(
                status="pendente",
                label="Timeout",
                description="Simula tempo esgotado e mantém o pedido pendente.",
            ),
        ]


class MercadoPagoPaymentProvider(BasePaymentProvider):
    provider = "mercado_pago"
    mode = "checkout_transparente_bricks"
    webhook_ready = True

    def __init__(
        self,
        *,
        provider_mode: str = "sandbox",
        public_key: str | None = None,
        poll_interval_ms: int = 3000,
    ) -> None:
        self.provider_mode = provider_mode
        self.public_key = public_key
        self.poll_interval_ms = poll_interval_ms

    def metadata(self) -> PaymentEngineMetadata:
        metadata = super().metadata()
        return PaymentEngineMetadata(
            provider=metadata.provider,
            mode=metadata.mode,
            methods=metadata.methods,
            future_provider=metadata.future_provider,
            webhook_ready=metadata.webhook_ready,
            scenarios=metadata.scenarios,
            mock_config=metadata.mock_config,
            public_key=self.public_key,
            provider_mode=self.provider_mode,
            poll_interval_ms=self.poll_interval_ms,
        )


def get_payment_provider(provider: str, mock_config: MockPaymentConfig | None = None) -> PaymentProvider:
    normalized = (provider or "mock").strip().lower()
    if normalized in {"mercado_pago", "mercado_pago_sandbox", "mercado_pago_prod"}:
        from backend.config.settings import get_settings

        settings = get_settings()
        mode = "prod" if normalized == "mercado_pago_prod" else "sandbox"
        return MercadoPagoPaymentProvider(
            provider_mode=mode,
            public_key=settings.mercado_pago_public_key or None,
            poll_interval_ms=settings.mercado_pago_poll_interval_ms,
        )
    return MockPaymentProvider(mock_config)
