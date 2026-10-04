package org.acme.orders;

import io.quarkus.hibernate.orm.panache.PanacheEntityBase;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.Table;

import java.time.OffsetDateTime;

/** Maps the existing table inventory.orders. created_at is filled by the database. */
@Entity
@Table(schema = "inventory", name = "orders")
public class PurchaseOrder extends PanacheEntityBase {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    public Integer id;

    @Column(name = "customer_id", nullable = false)
    public Integer customerId;

    @Column(nullable = false)
    public String product;

    @Column(nullable = false)
    public Integer quantity;

    @Column(name = "created_at", insertable = false, updatable = false)
    public OffsetDateTime createdAt;
}
