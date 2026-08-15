# frozen_string_literal: true

module Clickwrap
  # Base class for every error Clickwrap raises. Hosts can rescue this one
  # class and still distinguish causes through the subclasses below.
  class Error < StandardError; end

  # --- Configuration and boot -------------------------------------------------

  # Raised when the initializer contains a value Clickwrap cannot safely use.
  class ConfigurationError < Error; end

  # Raised while compiling a policy, document, or retention class definition.
  class DefinitionError < Error; end

  # Raised when a policy, document, statement, or retention class is referenced
  # but was never defined.
  class NotDefinedError < Error; end

  class UnknownPolicyError < NotDefinedError; end
  class UnknownDocumentError < NotDefinedError; end
  class UnknownStatementError < NotDefinedError; end
  class UnknownRetentionClassError < NotDefinedError; end

  # --- Documents --------------------------------------------------------------

  # Raised when a document version is required but has not been published, or
  # when stored bytes no longer match their recorded digest.
  class DocumentNotPublishedError < Error; end
  class DocumentDigestMismatchError < Error; end

  # Raised when a version label is reused for different bytes.
  class DocumentVersionConflictError < Error; end

  # --- Presentation and submission -------------------------------------------

  # Raised when the submitted presentation token is missing, malformed, signed
  # with a different key, expired, or bound to a different actor, tenant,
  # subject, policy, or revision than the one being captured.
  class PresentationInvalid < Error
    attr_reader :result

    def initialize(message = nil, result: nil)
      @result = result
      super(message || result&.message || "The presentation could not be verified")
    end
  end

  class PresentationExpired < PresentationInvalid; end

  # Raised when a submission cannot be parsed or contains keys the manifest
  # never declared.
  class SubmissionInvalid < Error; end

  # --- Capture ----------------------------------------------------------------

  # Raised when a required answer is missing or an answer is not one of the
  # choices the server offered.
  class AnswerInvalid < Error
    attr_reader :statement_key, :reason

    def initialize(message = nil, statement_key: nil, reason: nil)
      @statement_key = statement_key
      @reason = reason
      super(message || "The submitted answer for #{statement_key.inspect} was not accepted")
    end
  end

  # Raised when the evidence event itself could not be written. The protected
  # database action in the same transaction rolls back with it.
  class EventWriteFailed < Error; end

  # Raised when an identical idempotency key arrives with a different payload.
  class ReplayRejected < Error; end

  # Raised when a same-database protected action is requested but Clickwrap
  # cannot join the caller's transaction on the configured connection.
  class TransactionUnavailable < Error; end

  # Raised when a registration block returns without persisting the exact
  # prospective actor the presentation was issued for.
  class RegistrationFailed < Error; end

  # Raised when delegated action was not explicitly permitted by the policy and
  # positively verified by the host's authority callback.
  class AuthorityNotVerified < Error; end

  # Raised when a signed in-place remediation context is missing, expired,
  # belongs to a different actor/tenant/policy, or names a resource that can no
  # longer be resolved and authorized.
  class RemediationInvalid < Error; end
  class RemediationNotAuthorized < RemediationInvalid; end

  # Raised when a deadlock or serialization failure occurred and Clickwrap
  # cannot prove the caller's block is safe to retry. The host decides.
  class RetryableTransactionError < Error; end

  # --- Verification and gating ------------------------------------------------

  # Raised by the bang verification methods. Always carries the same structured
  # result the non-bang `Clickwrap.verify` would have returned, so applications
  # never parse an English message to make an authorization decision.
  class VerificationFailed < Error
    attr_reader :result

    def initialize(result)
      @result = result
      super(result.message)
    end

    def error = result.error
  end

  # --- Lifecycle --------------------------------------------------------------

  class LifecycleError < Error; end
  class AlreadyWithdrawnError < LifecycleError; end
  class AlreadyConsumedError < LifecycleError; end
  class OneTimeAuthorizationConflict < LifecycleError; end
  class NotWithdrawableError < LifecycleError; end

  # --- Request evidence, retention, and disposition ---------------------------

  # Raised when a policy requires IP address, browser user-agent, or IP
  # geolocation evidence and it could not be resolved.
  class RequestEvidenceUnavailable < Error; end

  # Raised when disposition is attempted on evidence under a legal hold.
  class LegalHoldInEffect < Error; end

  # Raised when ordinary Active Record mutation is attempted against evidence
  # whose only permitted changes are named, audited lifecycle transitions.
  class ImmutableEvidenceError < Error; end

  # Raised when a disposition plan is stale, already applied, expired, or no
  # longer matches what the operator reviewed.
  class DispositionPlanInvalid < Error; end

  # Raised when unredacted request evidence is requested without host
  # authorization or without a human-readable reason.
  class AccessNotAuthorized < Error; end

  # --- Integrity and receipts -------------------------------------------------

  # Raised when a receipt cannot be parsed, its schema version is unknown, or
  # its canonical bytes do not match the digest it carries.
  class ReceiptInvalid < Error; end
  class UnknownReceiptSchema < ReceiptInvalid; end
  class IntegrityCheckFailed < Error; end

  # Raised when a pending receipt is used after its transaction rolled back, or
  # when export/verification is called before commit.
  class ReceiptNotCommitted < Error; end

  # --- External actions -------------------------------------------------------

  class ExternalActionError < Error; end
  class ExternalActionAlreadyResolved < ExternalActionError; end
end
