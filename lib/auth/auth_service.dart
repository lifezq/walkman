class User {
  final String id;
  final String? phone;
  final String? nickname;
  User({required this.id, this.phone, this.nickname});
}

abstract class PhoneAuthService {
  Future<void> requestOtp(String phone);
  Future<User> loginWithOtp(String phone, String otp);
}

abstract class WeChatAuthService {
  Future<User> loginWithWeChat(String code);
}

class StubPhoneAuthService implements PhoneAuthService {
  @override
  Future<void> requestOtp(String phone) async {
    throw UnimplementedError('Phone OTP not implemented');
  }

  @override
  Future<User> loginWithOtp(String phone, String otp) async {
    throw UnimplementedError('Phone login not implemented');
  }
}

class StubWeChatAuthService implements WeChatAuthService {
  @override
  Future<User> loginWithWeChat(String code) async {
    throw UnimplementedError('WeChat login not implemented');
  }
}
