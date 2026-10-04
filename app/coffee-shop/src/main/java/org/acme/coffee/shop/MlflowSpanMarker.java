package org.acme.coffee.shop;

import io.opentelemetry.api.baggage.Baggage;
import io.opentelemetry.context.Context;
import io.opentelemetry.sdk.common.CompletableResultCode;
import io.opentelemetry.sdk.trace.ReadWriteSpan;
import io.opentelemetry.sdk.trace.ReadableSpan;
import io.opentelemetry.sdk.trace.SpanProcessor;
import jakarta.enterprise.context.ApplicationScoped;

/**
 * Marks every span started inside an AI trace (the order flow, see CoffeeResource) with
 * mlflow.export. The platform's OpenTelemetry collector forwards exactly those spans to MLflow;
 * all spans still go to Tempo. Quarkus registers SpanProcessor beans automatically.
 */
@ApplicationScoped
public class MlflowSpanMarker implements SpanProcessor {

    static final String BAGGAGE_KEY = "ai.trace";
    static final String ATTRIBUTE = "mlflow.export";

    @Override
    public void onStart(Context parentContext, ReadWriteSpan span) {
        String value = Baggage.fromContext(parentContext).getEntryValue(BAGGAGE_KEY);
        if (value != null) {
            span.setAttribute(ATTRIBUTE, value);
        }
    }

    @Override
    public boolean isStartRequired() {
        return true;
    }

    @Override
    public void onEnd(ReadableSpan span) {
        // nothing to do
    }

    @Override
    public boolean isEndRequired() {
        return false;
    }

    @Override
    public CompletableResultCode shutdown() {
        return CompletableResultCode.ofSuccess();
    }
}
