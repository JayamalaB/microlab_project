// Date of birth ↔ age, the same rules the customer "DOB or Age" fields use
// (customer add_member_screen.dart):
//  • picking a date gives the exact age today;
//  • typing an age gives a date of birth on today's day/month, that many
//    years back (age 0 = born this year).

/// Exact age in whole years on [today] (defaults to now).
int ageFromDob(DateTime dob, {DateTime? today}) {
  final now = today ?? DateTime.now();
  var age = now.year - dob.year;
  if (now.month < dob.month || (now.month == dob.month && now.day < dob.day)) {
    age--;
  }
  return age;
}

/// Estimated date of birth for [age]: today's day and month, [age] years back.
DateTime dobFromAge(int age, {DateTime? today}) {
  final now = today ?? DateTime.now();
  return DateTime(now.year - age, now.month, now.day);
}

/// DD/MM/YYYY, as shown in the DOB fields.
String formatDob(DateTime d) =>
    '${d.day.toString().padLeft(2, '0')}/${d.month.toString().padLeft(2, '0')}/${d.year}';
