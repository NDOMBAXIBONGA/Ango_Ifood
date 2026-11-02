/**
 * Tipagens TypeScript para o Portal do Parceiro Comercial (Onboarding, Status e Horários).
 * Regras: RN-010, RN-011, RN-012.
 */

export type StoreStatus = 'PENDENTE' | 'ATIVO' | 'PAUSADO' | 'SUSPENSO';

export interface BankDetails {
  banco: string;
  titularConta: string;
  numeroConta: string;
  iban: string;
  swiftBic?: string;
}

export interface DocumentUpload {
  file: File | null;
  fileName: string;
  fileSize: number;
  uploadedAt?: string;
  urlPreview?: string;
}

export interface CompanyDetails {
  nomeComercial: string;
  nif: string;
  telefone: string;
  email: string;
  moradaTexto: string;
  categoriaComercial: string;
}

export interface TimeSlot {
  id: string;
  horaAbertura: string; // Formato HH:MM
  horaFecho: string;    // Formato HH:MM
  isPausaTemporaria?: boolean;
}

export interface DaySchedule {
  diaSemana: number; // 0 = Segunda-feira .. 6 = Domingo
  diaNome: string;
  isEncerrado: boolean;
  turnos: TimeSlot[];
}

export interface PartnerStoreData {
  id?: string;
  empresa: CompanyDetails;
  dadosBancarios: BankDetails;
  licencaSanitaria: DocumentUpload;
  alvaraComercial: DocumentUpload;
  estado: StoreStatus;
  horariosSemanais: DaySchedule[];
  criadoEm?: string;
  atualizadoEm?: string;
}

export interface ApiSubmissionResult {
  sucesso: boolean;
  lojaId?: string;
  estado?: StoreStatus;
  mensagem: string;
  erros?: Record<string, string>;
}

