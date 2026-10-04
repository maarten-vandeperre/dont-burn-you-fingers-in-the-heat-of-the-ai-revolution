package org.acme.coffee.shop;

import io.quarkus.hibernate.orm.panache.PanacheEntityBase;
import jakarta.persistence.Column;
import jakarta.persistence.Entity;
import jakarta.persistence.GeneratedValue;
import jakarta.persistence.GenerationType;
import jakarta.persistence.Id;
import jakarta.persistence.JoinColumn;
import jakarta.persistence.ManyToOne;
import jakarta.persistence.Table;

/** coffee.order_lines: one line per drink variant of an order. */
@Entity
@Table(schema = "coffee", name = "order_lines")
public class CoffeeOrderLine extends PanacheEntityBase {

    @Id
    @GeneratedValue(strategy = GenerationType.IDENTITY)
    public Long id;

    @ManyToOne(optional = false)
    @JoinColumn(name = "order_id")
    public CoffeeOrder order;

    @Column(nullable = false) public String drink;
    @Column(nullable = false) public String size;
    @Column(nullable = false) public String milk;
    @Column(nullable = false) public boolean decaf;
    @Column(nullable = false) public int quantity;
    @Column(name = "unit_cents", nullable = false) public int unitCents;
    @Column(name = "total_cents", nullable = false) public int totalCents;
}
