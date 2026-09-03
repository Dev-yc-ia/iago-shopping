from pydantic import BaseModel


class PaymentScenario(BaseModel):
    status: str
    label: str
    description: str


class MockPaymentConfig(BaseModel):
    scenario: str
    delay_ms: int
    timeout_ms: int
    expiration_ms: int


class PaymentEngineResponse(BaseModel):
    provider: str
    mode: str
    methods: list[str]
    future_provider: str
    webhook_ready: bool
    public_key: str | None = None
    provider_mode: str | None = None
    poll_interval_ms: int = 3000
    scenarios: list[PaymentScenario]
    mock_config: MockPaymentConfig | None = None


class PaymentCreateRequest(BaseModel):
    order_id: str
    method: str = "pix"
    card_payload: dict | None = None


class PaymentCreateResponse(BaseModel):
    payment: dict
    provider_payload: dict | None = None


class PaymentSyncRequest(BaseModel):
    payment_id: str
    provider_payment_id: str | None = None


class PaymentCancelRequest(BaseModel):
    payment_id: str
    provider_payment_id: str | None = None


class PaymentWebhookResponse(BaseModel):
    received: bool
    provider_payment_id: str | None = None
    status: str | None = None
