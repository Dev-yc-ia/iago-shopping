# Services

Camada de regras de negócio e integrações desacopladas do backend.

Na Fase 9, `payment_engine.py` define o contrato de provedores de pagamento:

- `MockPaymentProvider`: simulação local sem movimentar dinheiro;
- `MercadoPagoPaymentProvider`: placeholder para Checkout Transparente Bricks;
- `get_payment_provider()`: ponto único de troca por configuração.
- cenários do Mock: `sempre_aprovar`, `sempre_recusar`, `aleatorio`, `timeout` e `expirar`.

As mudanças reais de pedido, estoque, auditoria, eventos e fila de e-mails continuam centralizadas nas RPCs do Supabase para preservar o padrão arquitetural atual do projeto. O cliente apenas inicia o pagamento; a confirmação vem do provider mock, preparando a troca futura para Mercado Pago sem alterar o frontend.
