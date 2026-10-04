package org.acme.projection;

import com.fasterxml.jackson.databind.ObjectMapper;
import io.micrometer.core.instrument.MeterRegistry;
import io.smallrye.reactive.messaging.annotations.Blocking;
import jakarta.enterprise.context.ApplicationScoped;
import jakarta.inject.Inject;
import org.apache.kafka.clients.consumer.ConsumerRecord;
import org.eclipse.microprofile.reactive.messaging.Incoming;
import org.jboss.logging.Logger;

/** Debezium topics in, MongoDB documents out. */
@ApplicationScoped
public class CdcConsumer {

    private static final Logger LOG = Logger.getLogger(CdcConsumer.class);

    @Inject ObjectMapper mapper;
    @Inject CustomerViewRepository views;
    @Inject MeterRegistry registry;

    @Incoming("customers")
    @Blocking
    public void onCustomer(ConsumerRecord<String, String> record) throws Exception {
        if (record.value() == null) {
            return; // tombstone after a delete, nothing to project
        }
        ChangeEvent event = ChangeEvent.parse(mapper, record.value());
        views.applyCustomer(event);
        processed(event);
    }

    @Incoming("orders")
    @Blocking
    public void onOrder(ConsumerRecord<String, String> record) throws Exception {
        if (record.value() == null) {
            return;
        }
        ChangeEvent event = ChangeEvent.parse(mapper, record.value());
        views.applyOrder(event);
        processed(event);
    }

    private void processed(ChangeEvent event) {
        registry.counter("cdc.events", "table", event.table(), "op", event.operation()).increment();
        long lagMs = event.sourceTsMs() == 0 ? 0 : System.currentTimeMillis() - event.sourceTsMs();
        registry.summary("cdc.lag.ms", "table", event.table()).record(lagMs);
        LOG.infof("projected %s %s (lag %d ms)", event.table(), event.operation(), lagMs);
    }
}
