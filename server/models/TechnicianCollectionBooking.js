'use strict';

const { DataTypes } = require('sequelize');
const sequelize = require('./sequelize');

module.exports = sequelize.define('TechnicianCollectionBooking', {
  collection_booking_id: { type: DataTypes.INTEGER, primaryKey: true, autoIncrement: true },
  booking_id:            { type: DataTypes.INTEGER, allowNull: false, unique: true },
  technician_id:         { type: DataTypes.INTEGER, allowNull: false },
  technician_name:       DataTypes.STRING(150),
  slot_id:               DataTypes.INTEGER,
  patient_id:            DataTypes.INTEGER,
  collection_date:       DataTypes.DATEONLY,
  collection_status: {
    type: DataTypes.ENUM('assigned', 'en_route', 'arrived', 'collected', 'completed', 'cancelled'),
    defaultValue: 'assigned',
  },
  assigned_at:           DataTypes.DATE,
  en_route_at:           DataTypes.DATE,
  arrived_at:            DataTypes.DATE,
  collected_at:          DataTypes.DATE,
  completed_at:          DataTypes.DATE,
  cancelled_at:          DataTypes.DATE,
  cancellation_reason:   DataTypes.STRING(255),
  collection_address:    DataTypes.TEXT,
  collection_latitude:   DataTypes.DECIMAL(10, 7),
  collection_longitude:  DataTypes.DECIMAL(10, 7),
  notes:                 DataTypes.TEXT,
  created_at:            DataTypes.DATE,
  updated_at:            DataTypes.DATE,
}, { tableName: 'technician_collection_booking', timestamps: false });
