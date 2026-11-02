import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

/// Localização Oficial da Aplicação Mobile para Angola (pt-AO).
/// Plataforma: Delivery / Ango_Ifood.
///
/// Substitui rigorosamente os termos:
/// - 'Estafeta' -> 'Entregador'
/// - 'Morada'   -> 'Endereço'
/// - 'Numerário' -> 'Dinheiro Físico'
/// E adota o Kwanza (Kz / AOA) como moeda oficial.
class AppLocalizationsPtAo {
  const AppLocalizationsPtAo();

  static const Locale locale = Locale('pt', 'AO');

  static AppLocalizationsPtAo of(BuildContext context) {
    return Localizations.of<AppLocalizationsPtAo>(context, AppLocalizationsPtAo) ??
        const AppLocalizationsPtAo();
  }

  // ===========================================================================
  // 1. CHAVES E EXPRESSÕES OBRIGATÓRIAS (Prompt & Regras de Negócio)
  // ===========================================================================
  String get homeTitle => 'Pedir Delivery';
  String get addressLabel => 'Endereço de Entrega';
  String get courierLabel => 'Entregador';
  String get courierStatusOnline => 'Estás Online! Pronto para receber corridas.';
  String get paymentCash => 'Dinheiro Físico (Pagar na Entrega)';
  String get currencySymbol => 'Kz';
  String errorMinimumOrder(String valor) =>
      'O total do carrinho é inferior ao pedido mínimo de $valor Kz requerido por esta loja.';
  String get registrationNif => 'Número de Identificação Fiscal (NIF Angolano)';
  String get registrationBi => 'Número do Bilhete de Identidade (BI)';
  String get ageRestrictionError =>
      'Operação Interrompida: Deves ter pelo menos 18 anos civis para consumir produtos regulados.';

  // ===========================================================================
  // 2. CONFIGURAÇÕES FINANCEIRAS E MOEDA (RN-059)
  // ===========================================================================
  String get currencyName => 'Kwanza Angolano';
  String get currencyIso => 'AOA';

  String formatCurrency(dynamic value) {
    if (value == null) return '0,00 Kz';
    double numVal;
    if (value is num) {
      numVal = value.toDouble();
    } else {
      numVal = double.tryParse(value.toString()) ?? 0.0;
    }
    // Formatação oficial angolana: separador de milhar por ponto e decimais por vírgula
    final parts = numVal.toStringAsFixed(2).split('.');
    final integerPart = parts[0].replaceAllMapped(
      RegExp(r'(\d{1,3})(?=(\d{3})+(?!\d))'),
      (Match m) => '${m[1]}.',
    );
    final decimalPart = parts[1];
    return '$integerPart,$decimalPart Kz';
  }

  String formatCentimos(int centimos) {
    return formatCurrency(centimos / 100.0);
  }

  // ===========================================================================
  // 3. MÓDULO DE AUTENTICAÇÃO E ONBOARDING (RN-001, RN-010, RN-082)
  // ===========================================================================
  String get roleSelectionTitle => 'Bem-vindo ao Ango_Ifood';
  String get roleSelectionSubtitle =>
      'Escolha como deseja interagir com a maior plataforma de entregas de Angola:';
  String get roleCustomerTitle => 'Quero Comprar';
  String get roleCustomerSubtitle =>
      'Peça refeições, compras de supermercado e produtos para entrega no seu endereço.';
  String get rolePartnerTitle => 'Tenho um Negócio';
  String get rolePartnerSubtitle =>
      'Venda mais, gira o seu cardápio e alcance milhares de clientes em Luanda e outras províncias.';
  String get roleCourierTitle => 'Quero Entregar';
  String get roleCourierSubtitle =>
      'Faça entregas na sua zona com a sua mota, carro ou bicicleta e receba repasses semanais.';

  String get phoneInputLabel => 'Número de Telemóvel';
  String get phoneInputPlaceholder => '9XXXXXXXX';
  String get phoneInputHelper =>
      'Suporta números da Unitel, Movicel ou Africell (+244).';
  String get phoneInputError =>
      'Introduza um número de telemóvel angolano válido com 9 dígitos.';
  String get otpTitle => 'Verificação de Segurança';
  String otpSubtitle(String phone) =>
      'Enviámos um código SMS de 6 dígitos para o número $phone.';
  String get otpResend => 'Reenviar código por SMS';
  String get otpVerifyButton => 'Confirmar e Entrar';

  // Validação Documental Angolana (AGT / DNIC)
  String get nifHelperText =>
      '10 dígitos para Empresas ou 14 caracteres do BI para Pessoa Singular.';
  String get nifInvalidError =>
      'NIF inválido. Assegure que cumpriu as regras da Administração Geral Tributária (AGT).';
  String get biHelperText =>
      'Exemplo: 004567890LA042 (9 dígitos, 2 letras provinciais e 3 dígitos finais).';
  String get biInvalidError =>
      'Formato de Bilhete de Identidade inválido ou sigla provincial desconhecida.';
  String get ibanLabel => 'IBAN Bancário para Liquidações';
  String get ibanPlaceholder => 'AO06 0000 0000 0000 0000 0000 0';
  String get ibanInvalidError =>
      'IBAN inválido. O padrão bancário angolano (EMIS) deve iniciar com AO06 (25 carateres).';

  // ===========================================================================
  // 4. MÓDULO DO CLIENTE (CATÁLOGO, CARRINHO, CHECKOUT E RASTREAMENTO)
  // ===========================================================================
  String get catalogSearchPlaceholder => 'Pesquisar restaurantes, pratos ou bebidas...';
  String get storeOpenStatus => 'Aberto Agora';
  String get storeClosedStatus => 'Fechado no Momento';
  String storeDeliveryEta(String minutes) => '$minutes min de entrega estimada';
  String storeMinimumOrderLabel(String valor) => 'Pedido mínimo: $valor Kz';

  String get cartTitle => 'O Meu Carrinho';
  String get cartEmptyMessage =>
      'O seu carrinho ainda está vazio. Escolha os seus pratos favoritos e faça o seu pedido!';
  String get cartSubtotal => 'Subtotal dos Produtos';
  String get cartDeliveryFee => 'Taxa de Entrega';
  String get cartServiceFee => 'Taxa Operacional da Plataforma';
  String get cartDiscount => 'Desconto de Cupão';
  String get cartTotal => 'Total a Pagar';
  String get cartCheckoutButton => 'Avançar para o Pagamento';

  // Opções de Pagamento em Angola
  String get paymentMethodTitle => 'Forma de Pagamento';
  String get paymentMulticaixaExpress => 'Multicaixa Express (MCX / EMIS)';
  String get paymentBankTransfer => 'Transferência Bancária / Referência';
  String get paymentWalletBalance => 'Saldo da Carteira Digital';
  String get changeNeededQuestion => 'Precisa de troco para dinheiro físico?';
  String get changeValuePlaceholder => 'Troco para quanto? (ex: 5.000 Kz)';

  // Telemetria e Tracking em Tempo Real (RN-094)
  String get orderStatusPlaced => 'Pedido Submetido à Loja';
  String get orderStatusAccepted => 'Loja a Preparar o Pedido';
  String get orderStatusCourierAssigned => 'Entregador Atribuído';
  String get orderStatusInTransit => 'Entregador a Caminho do seu Endereço';
  String get orderStatusDelivered => 'Pedido Entregue com Sucesso';
  String get pinDeliveryLabel => 'Código PIN de Confirmação';
  String get pinDeliveryInstruction =>
      'Partilhe este código PIN de 4 dígitos apenas presencialmente com o Entregador ao receber o pacote.';

  // ===========================================================================
  // 5. MÓDULO DO ENTREGADOR (CORRIDAS, GEOFENCING E CARTEIRA)
  // ===========================================================================
  String get courierStatusOffline => 'Estás Offline. Ativa o botão para começar a faturar.';
  String get courierToggleOnline => 'Ficar Online';
  String get courierToggleOffline => 'Ficar Offline';
  String get courierNewOfferTitle => 'Nova Corrida Disponível!';
  String courierOfferDistance(String km) => '$km km até ao estabelecimento';
  String courierEarningsEstimated(String valor) => 'Ganho estimado: $valor Kz';
  String get courierAcceptButton => 'Aceitar Corrida';
  String get courierRejectButton => 'Recusar';
  String get courierArrivedAtStore => 'Cheguei ao Estabelecimento';
  String get courierPickedUpOrder => 'Pedido Recolhido';
  String get courierConfirmDeliveryButton => 'Validar Entrega com PIN';
  String get courierEnterPinPlaceholder => 'Digite o PIN de 4 dígitos do cliente';

  // Carteira Financeira do Entregador (Secção 7)
  String get courierWalletTitle => 'A Minha Carteira';
  String get courierWeeklyBalance => 'Saldo Acumulado da Semana';
  String get courierEarlyWithdrawalButton => 'Antecipar Saldo para Conta Bancária';
  String get courierEarningsBreakdown => 'Extrato Discriminado de Corridas';
  String get courierBaseDeliveryFee => 'Valor Fixo Base da Corrida';
  String get courierKmDistanceFee => 'Adicional por Km Percorrido';
  String get courierStoreWaitBonus => 'Bónus por Espera Excessiva na Loja (>10 min)';
  String get courierSurgeBonus => 'Incentivo de Alta Procura / Chuva';
  String get courierTip100Percent => 'Gorjeta do Cliente (100% Repassada)';

  // ===========================================================================
  // 6. MÓDULO DO PARCEIRO COMERCIAL (PORTAL DO RESTAURANTE / LOJA)
  // ===========================================================================
  String get partnerPortalTitle => 'Terminal de Pedidos da Loja';
  String get partnerAccountPendingReview =>
      'Conta em Análise Documental: A sua licença sanitária e alvará comercial estão a ser validados pela nossa equipa de Operações.';
  String get partnerIncomingOrders => 'Pedidos a Entrar';
  String get partnerOrdersInKitchen => 'Em Preparação na Cozinha';
  String get partnerReadyForPickup => 'Pronto para Recolha do Entregador';
  String get partnerAcceptOrderButton => 'Aceitar Pedido (< 60s)';
  String get partnerRejectOrderButton => 'Rejeitar Pedido';
  String get partnerDispatchCourierButton => 'Chamar Entregador';

  // ===========================================================================
  // 7. MÓDULO DE SUPORTE, DISPUTAS E AJUDA (RN-138 A RN-142)
  // ===========================================================================
  String get supportHelpdeskTitle => 'Centro de Atendimento e Suporte';
  String get supportOpenDisputeButton => 'Reportar Problema com a Encomenda';
  String get disputeDamagedPackage => 'Embalagem ou Produto Danificado';
  String get disputeMissingItem => 'Item em Falta no Pedido';
  String get disputeLateDelivery => 'Atraso Excessivo na Entrega';
  String get disputeResolutionRefundWallet =>
      'Compensação aprovada: O valor foi creditado em Kwanzas (Kz) na sua Carteira Digital.';

  // ===========================================================================
  // 8. DICIONÁRIO DE TRADUÇÃO COMPLETO PARA CONSULTA DINÂMICA OU EXPORTAÇÃO JSON
  // ===========================================================================
  Map<String, dynamic> toMap() {
    return {
      // Chaves Obrigatórias
      'home_title': homeTitle,
      'address_label': addressLabel,
      'courier_label': courierLabel,
      'courier_status_online': courierStatusOnline,
      'payment_cash': paymentCash,
      'currency_symbol': currencySymbol,
      'error_minimum_order':
          'O total do carrinho é inferior ao pedido mínimo de {valor} Kz requerido por esta loja.',
      'registration_nif': registrationNif,
      'registration_bi': registrationBi,
      'age_restriction_error': ageRestrictionError,

      // Moeda e Finanças
      'currency_name': currencyName,
      'currency_iso': currencyIso,

      // Onboarding e Contas
      'role_selection_title': roleSelectionTitle,
      'role_customer_title': roleCustomerTitle,
      'role_partner_title': rolePartnerTitle,
      'role_courier_title': roleCourierTitle,
      'phone_input_label': phoneInputLabel,
      'phone_input_helper': phoneInputHelper,
      'nif_helper_text': nifHelperText,
      'bi_helper_text': biHelperText,
      'iban_label': ibanLabel,

      // Cliente
      'cart_title': cartTitle,
      'cart_delivery_fee': cartDeliveryFee,
      'cart_total': cartTotal,
      'payment_multicaixa_express': paymentMulticaixaExpress,
      'order_status_in_transit': orderStatusInTransit,
      'pin_delivery_label': pinDeliveryLabel,

      // Entregador
      'courier_status_offline': courierStatusOffline,
      'courier_new_offer_title': courierNewOfferTitle,
      'courier_wallet_title': courierWalletTitle,
      'courier_early_withdrawal': courierEarlyWithdrawalButton,
      'courier_base_delivery_fee': courierBaseDeliveryFee,

      // Parceiro
      'partner_portal_title': partnerPortalTitle,
      'partner_account_pending_review': partnerAccountPendingReview,
      'partner_ready_for_pickup': partnerReadyForPickup,

      // Suporte
      'support_helpdesk_title': supportHelpdeskTitle,
      'dispute_resolution_refund': disputeResolutionRefundWallet,
    };
  }
}

/// Delegado de Localização oficial para registo no `MaterialApp` do Flutter.
class AppLocalizationsPtAoDelegate
    extends LocalizationsDelegate<AppLocalizationsPtAo> {
  const AppLocalizationsPtAoDelegate();

  @override
  bool isSupported(Locale locale) {
    return locale.languageCode == 'pt';
  }

  @override
  Future<AppLocalizationsPtAo> load(Locale locale) {
    return SynchronousFuture<AppLocalizationsPtAo>(const AppLocalizationsPtAo());
  }

  @override
  bool shouldReload(AppLocalizationsPtAoDelegate old) => false;
}

/// Extensão no BuildContext para acesso direto: `context.l10n.homeTitle`
extension AppLocalizationsX on BuildContext {
  AppLocalizationsPtAo get l10n => AppLocalizationsPtAo.of(this);
}
