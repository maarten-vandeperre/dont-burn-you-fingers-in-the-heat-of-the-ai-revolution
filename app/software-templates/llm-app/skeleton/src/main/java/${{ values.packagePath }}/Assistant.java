package ${{ values.packageName }};

import dev.langchain4j.service.SystemMessage;
import dev.langchain4j.service.UserMessage;
import dev.langchain4j.service.V;
import io.quarkiverse.langchain4j.RegisterAiService;

/** LangChain4j AI service: the model behind it is configured in application.properties. */
@RegisterAiService(chatMemoryProviderSupplier = RegisterAiService.NoChatMemoryProviderSupplier.class)
public interface Assistant {

    @SystemMessage("{instructions}")
    @UserMessage("{question}")
    String answer(@V("instructions") String instructions, @V("question") String question);
}
