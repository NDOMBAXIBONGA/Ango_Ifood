/**
 * Tipos e Contratos para o Dashboard Corporativo de Gestão de Risco e Intervenção Operacional (Web ERP).
 * Módulos: Antifraude (6.14), Suporte/Disputas (6.15), Intervenção Manual (5.2, RN-088) e Blacklist (RN-135).
 */

export type FraudSeverity = 'BAIXA' | 'MEDIA' | 'ALTA' | 'CRITICA';

export type FraudType =
  | 'DISPOSITIVO_CARTAO_MULTICONTAS' // RN-131: >3 contas no mesmo hardware ou cartão
  | 'GPS_FALSO_VELOCIDADE_IMPOSSIVEL' // RN-133: Telemetria anómala / Mock location de estafeta
  | 'ABUSO_PROMOCOES_MORADA' // RN-132: Múltiplos vouchers de primeiro pedido na mesma morada
  | 'BLACKLIST_HIT' // RN-135: Correspondência com lista de bloqueio
  | 'PADRAO_SUSPEITO';

export interface FraudAlert {
  id: string;
  pedidoId?: string;
  utilizadorId: string;
  utilizadorNome: string;
  utilizadorTelemovel: string;
  utilizadorTipo: 'CLIENTE' | 'ESTAFETA' | 'PARCEIRO';
  tipoFraude: FraudType;
  severidade: FraudSeverity;
  scoreRisco: number; // 0 a 100
  descricao: string;
  evidencias: {
    deviceId?: string;
    cardFingerprint?: string;
    contasVinculadas?: string[];
    velocidadeCalculadaKmh?: number;
    distanciaSaltoKm?: number;
    moradaRepetida?: string;
    ipOrigem?: string;
    mockGpsDetected?: boolean;
    appAssinaturaInvalida?: boolean;
  };
  estadoConta: 'ATIVO' | 'SUSPENSO' | 'PENDENTE';
  dataAlerta: string;
  resolvido: boolean;
}

export type BlacklistIdentifierType =
  | 'TELEMOVEL'
  | 'EMAIL'
  | 'DEVICE_ID'
  | 'CARD_FINGERPRINT'
  | 'ESTAFETA_ID'
  | 'IP_ADDRESS';

export interface BlacklistEntry {
  id: string;
  tipoIdentificador: BlacklistIdentifierType;
  valorIdentificador: string;
  motivo: string;
  scoreRisco: number;
  evidenciaDescricao?: string;
  evidenciaFicheiroNome?: string;
  bloqueadoPor: string;
  dataBloqueio: string;
  isAtivo: boolean;
}

export type OrderStatus =
  | 'CRIADO'
  | 'CONFIRMADO_PARCEIRO'
  | 'EM_PREPARACAO'
  | 'ATRIBUINDO_ESTAFETA'
  | 'ESTAFETA_A_CAMINHO_RECOLHA'
  | 'EM_ENTREGA'
  | 'ENTREGUE'
  | 'CANCELADO';

export interface CriticalActiveOrder {
  id: string;
  codigoDisplay: string;
  lojaNome: string;
  lojaCoordenadas: [number, number]; // [lat, lng]
  clienteNome: string;
  clienteMorada: string;
  clienteCoordenadas: [number, number];
  tempoDecorridoMinutos: number;
  etaEstimadaMinutos: number;
  status: OrderStatus;
  alarmeCritico: boolean;
  motivoAlarme: string; // Ex: "Atraso crítico na preparação (> 20 min)" ou "Sem estafeta atribuído há 12 min (RN-088)"
  estafetaAtual?: {
    id: string;
    nome: string;
    telemovel: string;
    distanciaAteLojaKm: number;
  };
}

export interface AvailableCourier {
  id: string;
  nome: string;
  telemovel: string;
  veiculo: 'MOTO' | 'BICICLETA' | 'CARRO';
  distanciaKm: number;
  bateriaNivelPct: number;
  pedidosAtivosCount: number;
  classificacaoEstrelas: number;
  coordenadas: [number, number];
  gpsSeguro: boolean; // false se mock location detetado
}

export interface ManualReassignmentPayload {
  pedidoId: string;
  novoEstafetaId: string;
  motivoAuditoria: string;
  operadorId: string;
}
