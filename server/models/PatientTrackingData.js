'use strict';

const { DataTypes } = require('sequelize');
const sequelize = require('./sequelize');

module.exports = sequelize.define('PatientTrackingData', {
  tracking_id: { type: DataTypes.INTEGER, primaryKey: true, autoIncrement: true },
  booking_id:          { type: DataTypes.INTEGER, allowNull: false },
  tracked_entity_id:   DataTypes.INTEGER,
  latitude:            DataTypes.DECIMAL(10, 7),
  longitude:           DataTypes.DECIMAL(10, 7),
  accuracy_meters:     DataTypes.FLOAT,
  altitude_meters:     DataTypes.FLOAT,
  address_label:       DataTypes.STRING(255),
  location_stage:      DataTypes.STRING(50),
  device_id:           DataTypes.STRING(100),
  app_version:         DataTypes.STRING(20),
  source:              DataTypes.STRING(50),
  device_timestamp:    DataTypes.DATE,
  created_at:          DataTypes.DATE,
}, { tableName: 'ip_patient_tracking_data', timestamps: false });
