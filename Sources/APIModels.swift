import Foundation

struct APILanguage: Codable, Hashable, Identifiable {
    let language_id: String
    let name: String
    var id: String { language_id }
}

struct APIModel: Codable, Hashable, Identifiable {
    let model_id: String
    var name: String?
    var can_do_text_to_speech: Bool?
    var can_do_voice_conversion: Bool?
    var can_use_style: Bool?
    var can_use_speaker_boost: Bool?
    var serves_pro_voices: Bool?
    var description: String?
    var requires_alpha_access: Bool?
    var maximum_text_length_per_request: Int?
    var languages: [APILanguage]?
    var id: String { model_id }
    var displayName: String { name ?? model_id }
    // The TTS contract explicitly excludes Multilingual v2 from language_code.
    // Supported languages still come from the live model response.
    var supportsExplicitLanguage: Bool {
        can_do_text_to_speech == true && !model_id.contains("multilingual_v2") && !(languages ?? []).isEmpty
    }
}

struct VoiceLanguage: Codable, Hashable {
    let language: String
    let model_id: String
    var accent: String?
    var locale: String?
    var preview_url: String?
}

struct Voice: Codable, Identifiable, Hashable {
    let voice_id: String
    var name: String
    var category: String?
    var description: String?
    var preview_url: String?
    var labels: [String: String]?
    var verified_languages: [VoiceLanguage]?
    var high_quality_base_model_ids: [String]?
    var available_for_tiers: [String]?
    var permission_on_resource: String?
    var is_owner: Bool?
    var id: String { voice_id }
    // Do not infer ownership from category, presence in /voices, or a local create.
    var canEdit: Bool { is_owner == true && category != "premade" }
    var canDelete: Bool { canEdit }
    var canAdd: Bool { false }
    var languageSummary: String {
        let values = (verified_languages ?? []).map(\.language) + [labels?["language"]].compactMap { $0 }
        return Set(values).sorted().joined(separator: ", ")
    }
    init(voice_id: String, name: String) { self.voice_id = voice_id; self.name = name }
    enum CodingKeys: String, CodingKey {
        case voice_id, name, category, description, preview_url, labels, verified_languages
        case high_quality_base_model_ids, available_for_tiers, permission_on_resource, is_owner
    }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        voice_id = try c.decode(String.self, forKey: .voice_id)
        name = try c.decodeIfPresent(String.self, forKey: .name) ?? voice_id
        category = try c.decodeIfPresent(String.self, forKey: .category)
        description = try c.decodeIfPresent(String.self, forKey: .description)
        preview_url = try c.decodeIfPresent(String.self, forKey: .preview_url)
        labels = try c.decodeIfPresent([String: String].self, forKey: .labels)
        verified_languages = try c.decodeIfPresent([VoiceLanguage].self, forKey: .verified_languages)
        high_quality_base_model_ids = try c.decodeIfPresent([String].self, forKey: .high_quality_base_model_ids)
        available_for_tiers = try c.decodeIfPresent([String].self, forKey: .available_for_tiers)
        permission_on_resource = try c.decodeIfPresent(String.self, forKey: .permission_on_resource)
        is_owner = try c.decodeIfPresent(Bool.self, forKey: .is_owner)
    }
}
struct VoicePage: Decodable {
    let voices: [Voice]
    let has_more: Bool
    let next_page_token: String?
}
struct SharedVoice: Decodable, Hashable, Identifiable {
    let voice_id: String
    let public_owner_id: String
    let name: String
    var description: String?
    var preview_url: String?
    var language: String?
    var accent: String?
    var gender: String?
    var age: String?
    var category: String?
    var is_added_by_user: Bool?
    var free_users_allowed: Bool?
    var rate: Double?
    var verified_languages: [VoiceLanguage]?
    var id: String { public_owner_id + ":" + voice_id }
    var canAdd: Bool { is_added_by_user != true }
}
struct SharedVoicePage: Decodable {
    let voices: [SharedVoice]
    let has_more: Bool
    let total_count: Int?
}
struct AccountSubscription: Codable {
    let tier: String
    let character_count: Int
    let character_limit: Int
    var status: String?
    var next_character_count_reset_unix: Int?
    var voice_slots_used: Int?
    var voice_limit: Int?
    var can_use_instant_voice_cloning: Bool?
    var can_use_professional_voice_cloning: Bool?
    var can_extend_character_limit: Bool?
    // This subtraction is the remainder of the reported period allowance, not
    // an estimate of how much a particular operation will cost.
    var remainingCharacters: Int { max(0, character_limit - character_count) }
}
struct APIAccount: Decodable {
    let user_id: String
    var workspace_id: String?
    var first_name: String?
    var subscription: AccountSubscription?
    var seat_type: String?
    // Deliberately omit the API-key-preview field returned by the service.
}
struct VoiceCreationResult: Decodable {
    let voice_id: String
    var requires_verification: Bool?
}
struct VoiceDesignResult: Decodable {
    let previews: [VoiceDesignPreview]
    let text: String
}
struct VoiceDesignPreview: Decodable, Identifiable, Hashable {
    let generated_voice_id: String
    let audio_base_64: String
    let media_type: String
    var duration_secs: Double?
    var language: String?
    var id: String { generated_voice_id }
    var audio: Data? { Data(base64Encoded: audio_base_64) }
}
struct TranscriptionResult: Decodable {
    let text: String
    let language_code: String
    var language_probability: Double?
    var words: [TranscriptWord]?
    var transcription_id: String?
}
struct TranscriptWord: Decodable {
    let text: String
    var type: String?
    var start: Double?
    var end: Double?
    var speaker_id: String?
}
struct HistoryPage: Decodable {
    let history: [HistoryItem]
    let has_more: Bool
    let last_history_item_id: String?
}
struct HistoryItem: Decodable, Identifiable, Hashable {
    let history_item_id: String
    let date_unix: Int
    var voice_name: String?
    var voice_id: String?
    var model_id: String?
    var text: String?
    var source: String?
    var content_type: String?
    var output_format: String?
    var id: String { history_item_id }
}
struct DubbingProject: Codable, Identifiable {
    let project_id: String
    let status: String
    var source_language: String?
    var model_id: String?
    var language_ids: [String]?
    var error: DubbingError?
    var warnings: [DubbingWarning]?
    var id: String { project_id }
}
struct DubbingTarget: Codable, Identifiable {
    let language_id: String
    let project_id: String
    let target_language: String
    let status: String
    var outputs: DubbingOutputs?
    var error: DubbingError?
    var warnings: [DubbingWarning]?
    var id: String { language_id }
}
struct DubbingOutputs: Codable { var lossless_audio: String? }
struct DubbingError: Codable { let error: String }
struct DubbingWarning: Codable {
    let type: String
    let message: String
    var speaker_ids: [String]?
}
