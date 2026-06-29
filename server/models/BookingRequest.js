'use strict';

const { DataTypes } = require('sequelize');
const sequelize = require('./sequelize');

module.exports = sequelize.define('BookingRequest', {
  request_id:      { type: DataTypes.INTEGER, primaryKey: true, autoIncrement: true },
  booking_id:      { type: DataTypes.INTEGER, allowNull: false },
  technician_id:   { type: DataTypes.INTEGER, allowNull: false },
  technician_name: DataTypes.STRING(150),
  request_status:  { type: DataTypes.ENUM('pending', 'accepted', 'rejected', 'expired'), defaultValue: 'pending' },
  total_attempts:  { type: DataTypes.TINYINT, defaultValue: 0 },
  max_attempts:    { type: DataTypes.TINYINT, defaultValue: 3 },
  next_attempt_at: DataTypes.DATE,
  last_sent_at:    DataTypes.DATE,
  responded_at:    DataTypes.DATE,
  created_at:      DataTypes.DATE,
  updated_at:      DataTypes.DATE,
}, { tableName: 'ip_booking_requests', timestamps: false });
