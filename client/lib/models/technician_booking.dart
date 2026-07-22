class TechnicianBooking {
  final String id;
  final String? bookingRef;
  final int? patientId;
  final String customerName;
  final String customerPhone;
  final String address;
  final String city;
  final String pincode;
  final DateTime date;
  final String timeSlot;
  final List<String> testNames;
  final String mode;
  final String status;
  final bool isVip;
  final bool docRequired;
  final bool docVerified;
  final double serviceChargePaid;
  final double testsTotal;
  final double amountPaid;
  final String paymentStatus;
  final DateTime? assignedAt;
  final String? visitGroupId;
  // Navigation fields — populated for socket-assigned bookings
  final double? patientLat;
  final double? patientLng;
  final String hospital;

  TechnicianBooking({
    required this.id,
    this.bookingRef,
    this.patientId,
    required this.customerName,
    required this.customerPhone,
    required this.address,
    required this.city,
    required this.pincode,
    required this.date,
    required this.timeSlot,
    required this.testNames,
    required this.mode,
    required this.status,
    this.isVip = false,
    this.docRequired = false,
    this.docVerified = false,
    this.serviceChargePaid = 99.0,
    this.testsTotal = 0.0,
    this.amountPaid = 0.0,
    this.paymentStatus = 'pending',
    this.assignedAt,
    this.visitGroupId,
    this.patientLat,
    this.patientLng,
    this.hospital = '',
  });
}
