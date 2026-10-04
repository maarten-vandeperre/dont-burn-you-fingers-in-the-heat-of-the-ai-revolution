package ${{ values.packageName }};

/**
 * The use case chosen in Developer Hub. The platform maps it to a model (application.properties,
 * llm.model) and gives each use case its own instructions.
 */
public enum UseCase {

    OVERALL_KNOWLEDGE("Overall knowledge",
            "You are a helpful assistant for general knowledge questions. Answer clearly and concisely. "
            + "If you are not sure, say so instead of guessing."),

    CODING_QUESTIONS("Coding questions",
            "You are a senior software engineer. Answer programming questions with short explanations "
            + "and, where useful, a small code example in a markdown code block."),

    MEDICAL_QUESTIONS("Medical questions",
            "You give general health information only. You do not diagnose, prescribe or replace a doctor. "
            + "Keep answers factual and cautious, and advise to consult a healthcare professional for "
            + "personal medical questions. For emergencies, tell the user to contact emergency services."),

    FOOD_QUESTIONS("Food questions",
            "You are a friendly cooking and nutrition assistant. Help with recipes, ingredients, "
            + "substitutions and general nutrition facts. Mention common allergens when relevant.");

    private final String label;
    private final String instructions;

    UseCase(String label, String instructions) {
        this.label = label;
        this.instructions = instructions;
    }

    public String label() {
        return label;
    }

    public String instructions() {
        return instructions;
    }
}
