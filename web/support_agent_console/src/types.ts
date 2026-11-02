/**
 * Tipagens TypeScript para a Consola de Atendimento do Agente de Suporte (SupportAgentConsole).
 * Regras: RN-101, RN-106, RN-138, RN-139, RN-140, RN-141, RN-142, RN-071, RN-105.
 */

export type TicketPriority = 'BAIXA' | 'MEDIA' | 'ALTA' | 'CRITICA';

export type TicketType =
  | 'REACAO_ALERGICA' // RN-140 (SLA < 5 min emergencial)
  | 'INTOXICACAO_ALIMENTAR' // RN-140 (SLA < 5 min emergencial)
  | 'DERRAME_DANOS' // RN-101 (Evidência fotográfica)
  | 'ITEM_FALTOU'
  | 'ATRASO_GRAVE'
  | 'DISPUTA_COMERCIAL';

export type TicketState = 'ABERTO' | 'EM_ANALISE' | 'RESOLVIDO';

export type DisputeDecision = 'Procedente_Cliente' | 'Procedente_Parceiro' | 'Improcedente';

export interface ChatMessage {
  id: string;
  remetenteTipo: 'CLIENTE' | 'ESTAFETA' | 'LOJA' | 'SISTEMA' | 'SUPORTE';
  remetenteNome: string;
  conteudo: string; // Conteúdo com máscaras de segurança para dados sensíveis
  timestamp: string;
  isAnexoFoto?: boolean;
  fotoUrl?: string;
}

export interface OrderStateTimelineItem {
  estado: string;
  descricao: string;
  timestamp: string;
  concluido: boolean;
}

export interface EvidencePhoto {
  id: string;
  url: string;
  legenda: string;
  autor: 'ESTAFETA' | 'CLIENTE';
  dataEnvio: string;
}

export interface SupportTicket {
  id: string;
  pedidoId: string;
  codigoDisplay: string;
  clienteNome: string;
  clienteTelemovelMascarado: string;
  lojaNome: string;
  lojaNif: string;
  itensResumo: string;
  subtotalKz: number;
  totalKz: number;
  tipoIncidente: TicketType;
  prioridade: TicketPriority;
  estado: TicketState;
  motivoAbertura: string;
  tempoRestanteSlaSegundos: number; // Para contagem decrescente do SLA de 5 min (RN-139)
  slaCriticoMinutos: number;
  criadoEm: string;
  mensagensChat: ChatMessage[];
  evidenciasFotos: EvidencePhoto[];
  timelinePedido: OrderStateTimelineItem[];
  decisaoResolucao?: {
    decisao: DisputeDecision;
    motivoJustificacao: string;
    compensacaoValorKz: number;
    autorEmail: string;
    supervisorAprovadorEmail?: string;
    resolvidoEm: string;
  };
}

export interface DisputeResolutionPayload {
  pedidoId: string;
  ticketId: string;
  decisao: DisputeDecision;
  motivoJustificacao: string;
  compensacaoValorCentimos: number; // Inteiro em cêntimos (RN-059)
  supervisorAprovadorPin?: string;
  supervisorAprovadorId?: string;
}

