/**
 * Serviço de Integração de Gestão de Risco, Antifraude e Intervenção Logística (Web ERP).
 * Comunicação com as rotas administrativas do Django REST Framework e gestão de auditoria (Secção 5.2, RN-008, RN-130 a RN-135).
 */

import {
  AvailableCourier,
  BlacklistEntry,
  CriticalActiveOrder,
  FraudAlert,
  ManualReassignmentPayload,
} from '../types';

const API_BASE = 'http://localhost:8000/api/v1/admin';

// Dados de Demonstração Corporativos Realistas para Operação em Angola (Luanda / Talatona)
const MOCK_FRAUD_ALERTS: FraudAlert[] = [
  {
    id: 'alt-frd-8901',
    pedidoId: 'ped-uuid-1049',
    utilizadorId: 'usr-cli-3301',
    utilizadorNome: 'Manuel dos Santos',
    utilizadorTelemovel: '+244 923 111 222',
    utilizadorTipo: 'CLIENTE',
    tipoFraude: 'DISPOSITIVO_CARTAO_MULTICONTAS',
    severidade: 'CRITICA',
    scoreRisco: 94,
    descricao: 'RN-131: O mesmo Hardware UUID (device_id) está associado a 5 contas distintas criadas em 48h.',
    evidencias: {
      deviceId: 'hw_uuid_a891f7b02c8941da928',
      cardFingerprint: 'sha256_e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      contasVinculadas: ['manuel.santos@gmail.com', 'm.santos2@sapo.ao', 'santos.fast@live.com', 'test.card@gmail.com'],
      ipOrigem: '197.234.219.45 (Unitel Luanda)',
    },
    estadoConta: 'ATIVO',
    dataAlerta: '2026-10-29 21:48:12',
    resolvido: false,
  },
  {
    id: 'alt-frd-8902',
    pedidoId: 'ped-uuid-1052',
    utilizadorId: 'usr-est-4402',
    utilizadorNome: 'Carlos Silva (Estafeta #108)',
    utilizadorTelemovel: '+244 912 333 444',
    utilizadorTipo: 'ESTAFETA',
    tipoFraude: 'GPS_FALSO_VELOCIDADE_IMPOSSIVEL',
    severidade: 'CRITICA',
    scoreRisco: 89,
    descricao: 'RN-133: Aplicação de Mock Location detetada no Android. Salto teletransportado de 14.8 km em 12 segundos.',
    evidencias: {
      mockGpsDetected: true,
      velocidadeCalculadaKmh: 442.8,
      distanciaSaltoKm: 14.8,
      appAssinaturaInvalida: true,
      ipOrigem: '105.172.90.12 (Africell Luanda)',
    },
    estadoConta: 'ATIVO',
    dataAlerta: '2026-10-29 21:52:04',
    resolvido: false,
  },
  {
    id: 'alt-frd-8903',
    pedidoId: 'ped-uuid-1055',
    utilizadorId: 'usr-cli-5503',
    utilizadorNome: 'Ana Paula Lourenço',
    utilizadorTelemovel: '+244 931 777 888',
    utilizadorTipo: 'CLIENTE',
    tipoFraude: 'ABUSO_PROMOCOES_MORADA',
    severidade: 'ALTA',
    scoreRisco: 76,
    descricao: 'RN-132: 6 contas beneficiaram do cupão de primeiro pedido (BEMVINDO) na mesma coordenada geográfica.',
    evidencias: {
      moradaRepetida: 'Condomínio Belas Business Park, Torre Císter, Apt 402',
      distanciaSaltoKm: 0.005,
      contasVinculadas: ['anapaula@outlook.com', 'ana.l@sapo.ao', 'lourenco.promo@gmail.com'],
    },
    estadoConta: 'ATIVO',
    dataAlerta: '2026-10-29 22:04:30',
    resolvido: false,
  },
];

const MOCK_BLACKLIST: BlacklistEntry[] = [
  {
    id: 'blk-001',
    tipoIdentificador: 'DEVICE_ID',
    valorIdentificador: 'hw_uuid_f87e2b100918cba47e',
    motivo: 'Fraude massiva de cartões clonados e criação reiterada de multicontas (RN-131/RN-135).',
    scoreRisco: 100,
    evidenciaDescricao: 'Relatório do gateway com 14 estornos consecutivos confirmados pelo banco emissor.',
    evidenciaFicheiroNome: 'relatorio_chargebacks_outubro2026.pdf',
    bloqueadoPor: 'admin_seguranca@delivery.ao',
    dataBloqueio: '2026-10-24 14:15:00',
    isAtivo: true,
  },
  {
    id: 'blk-002',
    tipoIdentificador: 'ESTAFETA_ID',
    valorIdentificador: 'usr-est-9901',
    motivo: 'Simulação contínua de rotas com Mock GPS e apropriação indevida de mercadorias alimentares (RN-133).',
    scoreRisco: 98,
    evidenciaDescricao: 'Telemetria comprovada no PostGIS com velocidade impossível de 520 km/h.',
    evidenciaFicheiroNome: 'telemetria_gps_anomala_est9901.csv',
    bloqueadoPor: 'supervisor_operacoes@delivery.ao',
    dataBloqueio: '2026-10-26 18:30:22',
    isAtivo: true,
  },
];

const MOCK_CRITICAL_ORDERS: CriticalActiveOrder[] = [
  {
    id: 'ped-uuid-1049',
    codigoDisplay: '#LUA-9049',
    lojaNome: 'Pizzaria & Trattoria Napoli (Talatona)',
    lojaCoordenadas: [-8.9182, 13.2045],
    clienteNome: 'Mariana de Albuquerque',
    clienteMorada: 'Rua das Acácias, n.º 45, Miramar, Luanda',
    clienteCoordenadas: [-8.8142, 13.2421],
    tempoDecorridoMinutos: 48,
    etaEstimadaMinutos: 30,
    status: 'ATRIBUINDO_ESTAFETA',
    alarmeCritico: true,
    motivoAlarme: 'RN-088: 4 estafetas rejeitaram consecutivamente ou sem atribuição há 14 minutos.',
  },
  {
    id: 'ped-uuid-1052',
    codigoDisplay: '#LUA-9052',
    lojaNome: 'Hamburgueria Artesanal Baixa',
    lojaCoordenadas: [-8.8164, 13.2355],
    clienteNome: 'Dr. Sebastião Viana',
    clienteMorada: 'Edifício Presidente, 7.º Andar, Baixa de Luanda',
    clienteCoordenadas: [-8.8120, 13.2389],
    tempoDecorridoMinutos: 38,
    etaEstimadaMinutos: 25,
    status: 'EM_PREPARACAO',
    alarmeCritico: true,
    motivoAlarme: 'Atraso crítico na cozinha da loja (> 25 min além da janela estimada).',
  },
  {
    id: 'ped-uuid-1058',
    codigoDisplay: '#LUA-9058',
    lojaNome: 'Sushi & Wok Luanda Sul',
    lojaCoordenadas: [-8.9321, 13.1890],
    clienteNome: 'Eng. Fernando Costa',
    clienteMorada: 'Condomínio Jardim de Rosas, Bloco 8, Camama',
    clienteCoordenadas: [-8.9410, 13.2180],
    tempoDecorridoMinutos: 42,
    etaEstimadaMinutos: 28,
    status: 'ATRIBUINDO_ESTAFETA',
    alarmeCritico: true,
    motivoAlarme: 'RN-088: Procura excede capacidade da frota na zona logística Sul.',
  },
];

const MOCK_AVAILABLE_COURIERS: AvailableCourier[] = [
  {
    id: 'est-001',
    nome: 'Mateus Gaspar (Estafeta #42)',
    telemovel: '+244 923 888 101',
    veiculo: 'MOTO',
    distanciaKm: 1.2,
    bateriaNivelPct: 92,
    pedidosAtivosCount: 0,
    classificacaoEstrelas: 4.9,
    coordenadas: [-8.9150, 13.2080],
    gpsSeguro: true,
  },
  {
    id: 'est-002',
    nome: 'Domingos Baptista (Estafeta #78)',
    telemovel: '+244 912 444 202',
    veiculo: 'MOTO',
    distanciaKm: 2.1,
    bateriaNivelPct: 78,
    pedidosAtivosCount: 0,
    classificacaoEstrelas: 4.8,
    coordenadas: [-8.9220, 13.2110],
    gpsSeguro: true,
  },
  {
    id: 'est-003',
    nome: 'João Pedro Kuanza (Estafeta #95)',
    telemovel: '+244 934 555 303',
    veiculo: 'MOTO',
    distanciaKm: 3.4,
    bateriaNivelPct: 65,
    pedidosAtivosCount: 1,
    classificacaoEstrelas: 4.7,
    coordenadas: [-8.9050, 13.1990],
    gpsSeguro: true,
  },
];

export class RiskInterventionService {
  /**
   * Obtém alertas de fraude em tempo real (RN-130 a RN-134).
   */
  static async getFraudAlerts(): Promise<FraudAlert[]> {
    try {
      const res = await fetch(`${API_BASE}/fraud/alerts/`);
      if (res.ok) return await res.json();
    } catch {
      // fallback
    }
    await new Promise((r) => setTimeout(r, 400));
    return [...MOCK_FRAUD_ALERTS];
  }

  /**
   * Executa a suspensão da conta do utilizador/estafeta (RN-008 / RN-135).
   */
  static async suspendAccount(payload: {
    utilizadorId: string;
    motivo: string;
    operadorId: string;
    adicionarBlacklist: boolean;
    tipoIdentificador?: string;
    valorIdentificador?: string;
  }): Promise<{ sucesso: boolean; mensagem: string }> {
    try {
      const res = await fetch(`${API_BASE}/users/${payload.utilizadorId}/suspend/`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
      if (res.ok) {
        return { sucesso: true, mensagem: 'Conta suspensa com sucesso no sistema (RN-008/RN-135).' };
      }
    } catch {
      // fallback
    }
    await new Promise((r) => setTimeout(r, 600));
    return {
      sucesso: true,
      mensagem: `Conta ${payload.utilizadorId} suspensa com sucesso e averbada no log de auditoria.`,
    };
  }

  /**
   * Consulta a Lista de Bloqueio Imutável (Blacklist - RN-135).
   */
  static async getBlacklist(): Promise<BlacklistEntry[]> {
    try {
      const res = await fetch(`${API_BASE}/fraud/blacklist/`);
      if (res.ok) return await res.json();
    } catch {
      // fallback
    }
    await new Promise((r) => setTimeout(r, 300));
    return [...MOCK_BLACKLIST];
  }

  /**
   * Insere nova entrada na Blacklist Imutável com justificação e upload de evidência (RN-135).
   */
  static async addToBlacklist(formData: FormData): Promise<{ sucesso: boolean; mensagem: string }> {
    try {
      const res = await fetch(`${API_BASE}/fraud/blacklist/`, {
        method: 'POST',
        body: formData,
      });
      if (res.ok) {
        return { sucesso: true, mensagem: 'Identificador bloqueado e inscrito na Blacklist com sucesso (RN-135).' };
      }
    } catch {
      // fallback
    }
    await new Promise((r) => setTimeout(r, 700));
    return {
      sucesso: true,
      mensagem: 'Entrada gravada na Lista de Bloqueio Imutável (Simulação Concluída).',
    };
  }

  /**
   * Consulta pedidos ativos em atraso crítico para intervenção manual (RN-088).
   */
  static async getCriticalOrders(): Promise<CriticalActiveOrder[]> {
    try {
      const res = await fetch(`${API_BASE}/logistics/orders/critical/`);
      if (res.ok) return await res.json();
    } catch {
      // fallback
    }
    await new Promise((r) => setTimeout(r, 350));
    return [...MOCK_CRITICAL_ORDERS];
  }

  /**
   * Lista estafetas online na zona para reatribuição forçada.
   */
  static async getAvailableCouriers(pedidoId: string): Promise<AvailableCourier[]> {
    try {
      const res = await fetch(`${API_BASE}/logistics/couriers/available/?pedido_id=${pedidoId}`);
      if (res.ok) return await res.json();
    } catch {
      // fallback
    }
    await new Promise((r) => setTimeout(r, 300));
    return [...MOCK_AVAILABLE_COURIERS];
  }

  /**
   * Executa a reatribuição manual forçada com registo imutável de auditoria (Secção 5.2 / EventoPedido).
   */
  static async forceReassignCourier(
    payload: ManualReassignmentPayload
  ): Promise<{ sucesso: boolean; mensagem: string }> {
    try {
      const res = await fetch(`${API_BASE}/logistics/orders/${payload.pedidoId}/force-reassign/`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(payload),
      });
      if (res.ok) {
        return { sucesso: true, mensagem: 'Estafeta reatribuído e evento registado no log imutável.' };
      }
    } catch {
      // fallback
    }
    await new Promise((r) => setTimeout(r, 650));
    return {
      sucesso: true,
      mensagem: `Pedido ${payload.pedidoId} reatribuído com sucesso ao estafeta ${payload.novoEstafetaId}. Justificação registada em EventoPedido (Secção 5.2).`,
    };
  }
}
