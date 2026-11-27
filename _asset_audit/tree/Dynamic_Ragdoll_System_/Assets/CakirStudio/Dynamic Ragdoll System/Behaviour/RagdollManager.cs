using System.Collections;
using System.Collections.Generic;
using UnityEngine;

namespace DynamicRagdoll
{
    public class RagdollManager : MonoBehaviour
    {
        public List<JointSpringInfo> jointSpringList;
        public List<PartTypeInfo> partTypeList;
        public enum JointType
        {
            hips,
            leftThigh,
            leftKnee,
            leftFoot,
            rightThigh,
            rightKnee,
            rightFoot,
            leftArm,
            leftElbow,
            rightArm,
            rightElbow,
            middleSpine,
            head
        }

        public enum PartType
        {
            Spine1,
            Spine3,
            leftScapula,
            rightScapula,
            leftToe,
            rightToe,
            leftHand,
            rightHand,
            neck,
        }

        [System.Serializable]
        public struct JointSpringInfo
        {
            public JointType jointType;
            public ConfigurableJoint joint;
            public float mainSpring;
            public float mainDamping;
            public JointSpringInfo(ConfigurableJoint _joint, JointType _Jointtype, float _mainSpring, float _mainDamping)
            {
                jointType = _Jointtype;
                joint = _joint;
                mainSpring = _mainSpring;
                mainDamping = _mainDamping;
            }

            public void FixJoint()
            {
                JointDrive drive = joint.slerpDrive;
                drive.positionSpring = mainSpring;
                drive.positionDamper = mainDamping;
                joint.slerpDrive = drive;
            }
            public void LooseJoint()
            {
                JointDrive drive = joint.slerpDrive;
                drive.positionSpring = 0f;
                drive.positionDamper = 0f;
                drive.maximumForce = float.MaxValue;
                joint.slerpDrive = drive;
            }
        }

        [System.Serializable]
        public struct PartTypeInfo
        {
            public PartType partType;
            public Transform part;
            public Quaternion mainRot;

            public PartTypeInfo(Transform _part, Quaternion _mainRot,PartType _partType)
            {
                part = _part;
                mainRot = _mainRot;
                partType = _partType;
            }
        }
        public PartTypeInfo GetPartByPartType(PartType partType)
        {
            foreach (var partInfo in partTypeList)
            {
                if (partInfo.partType == partType) 
                {
                    return partInfo;
                }
            }

            return default;
        }
        public void BackTPos()
        {
            Quaternion _Spine1Current = GetPartByPartType(PartType.Spine1).part.localRotation;
            Quaternion _Spine3Current = GetPartByPartType(PartType.Spine3).part.localRotation;
            Quaternion _LscapulaCurrent = GetPartByPartType(PartType.leftScapula).part.localRotation;
            Quaternion _RscapulaCurrent = GetPartByPartType(PartType.rightScapula).part.localRotation;
            Quaternion _LtoeCurrent = GetPartByPartType(PartType.leftToe).part.localRotation;
            Quaternion _RtoeCurrent = GetPartByPartType(PartType.rightToe).part.localRotation;
            Quaternion _LhandCurrent = GetPartByPartType(PartType.leftHand).part.localRotation;
            Quaternion _RhandCurrent = GetPartByPartType(PartType.rightHand).part.localRotation;
            Quaternion _neckCurrent = GetPartByPartType(PartType.neck).part.localRotation;

            StartCoroutine(LerpBodyParts(0.5f, _Spine1Current, _Spine3Current, _LscapulaCurrent, _RscapulaCurrent, _LtoeCurrent, _RtoeCurrent,
            _LhandCurrent, _RhandCurrent, _neckCurrent));
        }
        private IEnumerator LerpBodyParts(float duration, Quaternion Spine1Current, Quaternion Spine3Current, Quaternion LscapulaCurrent, Quaternion RscapulaCurrent, Quaternion LtoeCurrent, Quaternion RtoeCurrent,
            Quaternion LhandCurrent, Quaternion RhandCurrent, Quaternion neckCurrent)
        {
            float elapsedTime = 0f;

            Transform Spine1 = GetPartByPartType(PartType.Spine1).part;
            Transform Spine3 = GetPartByPartType(PartType.Spine3).part;
            Transform leftScapula = GetPartByPartType(PartType.leftScapula).part;
            Transform rightScapula = GetPartByPartType(PartType.rightScapula).part;
            Transform leftToe = GetPartByPartType(PartType.leftToe).part;
            Transform rightToe = GetPartByPartType(PartType.rightToe).part;
            Transform leftHand = GetPartByPartType(PartType.leftHand).part;
            Transform rightHand = GetPartByPartType(PartType.rightHand).part;
            Transform neck = GetPartByPartType(PartType.neck).part;

            Quaternion targetSpine1 = GetPartByPartType(PartType.Spine1).mainRot;
            Quaternion targetSpine3 = GetPartByPartType(PartType.Spine3).mainRot;
            Quaternion targetleftScapula = GetPartByPartType(PartType.leftScapula).mainRot;
            Quaternion targetrightScapula = GetPartByPartType(PartType.rightScapula).mainRot;
            Quaternion targetleftToe = GetPartByPartType(PartType.leftToe).mainRot;
            Quaternion targetrightToe = GetPartByPartType(PartType.rightToe).mainRot;
            Quaternion targetleftHand = GetPartByPartType(PartType.leftHand).mainRot;
            Quaternion targetrightHand = GetPartByPartType(PartType.rightHand).mainRot;
            Quaternion targetneck = GetPartByPartType(PartType.neck).mainRot;

            while (elapsedTime < duration)
            {
                float t = elapsedTime / duration;

                Spine1.localRotation = Quaternion.Lerp(Spine1Current, targetSpine1, t);
                Spine3.localRotation = Quaternion.Lerp(Spine3Current, targetSpine3, t);
                leftScapula.localRotation = Quaternion.Lerp(LscapulaCurrent, targetleftScapula, t);
                rightScapula.localRotation = Quaternion.Lerp(RscapulaCurrent, targetrightScapula, t);
                leftToe.localRotation = Quaternion.Lerp(LtoeCurrent, targetleftToe, t);
                rightToe.localRotation = Quaternion.Lerp(RtoeCurrent, targetrightToe, t);
                leftHand.localRotation = Quaternion.Lerp(LhandCurrent, targetleftHand, t);
                rightHand.localRotation = Quaternion.Lerp(RhandCurrent, targetrightHand, t);
                neck.localRotation = Quaternion.Lerp(neckCurrent, targetneck, t);

                elapsedTime += Time.deltaTime;
                yield return null;
            }

            Spine1.localRotation = targetSpine1;
            Spine3.localRotation = targetSpine3;
            leftScapula.localRotation = targetleftScapula;
            rightScapula.localRotation = targetrightScapula;
            leftToe.localRotation = targetleftToe;
            rightToe.localRotation = targetrightToe;
            leftHand.localRotation = targetleftHand;
            rightHand.localRotation = targetrightHand;
            neck.localRotation = targetneck;
            yield return null;
        }

        public JointSpringInfo GetSpringByJointType(JointType jointType)
        {
            foreach (var jointInfo in jointSpringList)
            {
                if (jointInfo.jointType == jointType)
                {
                    return jointInfo;
                }
            }

            return default;
        }

        public void NormalRagdoll()
        {
            foreach (var jointInfo in jointSpringList)
            {
                if (jointInfo.joint == null)
                {
                    continue;
                }

                JointDrive drive = jointInfo.joint.slerpDrive;

                if (jointInfo.jointType == JointType.hips)
                {
                    drive.positionSpring = 0;
                    drive.positionDamper = 0;
                    drive.maximumForce = float.MaxValue;
                    jointInfo.joint.slerpDrive = drive;
                }
                else
                {
                    jointInfo.LooseJoint();
                }
            }
        }
        public void DynamicRagdoll()
        {
            foreach (var jointInfo in jointSpringList)
            {
                if (jointInfo.joint == null)
                {
                    continue;
                }

                jointInfo.FixJoint();
            }
        }
        public void DoKinematic()
        {
            foreach (var jointInfo in jointSpringList)
            {
                if (jointInfo.joint == null)
                {
                    continue;
                }

                Rigidbody rb = jointInfo.joint.GetComponent<Rigidbody>();

                if (rb.isKinematic == false)
                {
                    rb.linearVelocity = Vector3.zero;
                    rb.angularVelocity = Vector3.zero;
                }

                rb.isKinematic = true;

            }
        }
        public void ReKinematic()
        {
            foreach (var jointInfo in jointSpringList)
            {
                if (jointInfo.joint == null)
                {
                    continue;
                }

                Rigidbody rb = jointInfo.joint.GetComponent<Rigidbody>();

                rb.isKinematic = false;
            }
        }
        public void IgnoreCollisions()
        {
            Physics.IgnoreCollision(GetSpringByJointType(JointType.middleSpine).joint.gameObject.GetComponent<BoxCollider>(), GetSpringByJointType(JointType.hips).joint.gameObject.GetComponent<BoxCollider>(), true);
            Physics.IgnoreCollision(GetSpringByJointType(JointType.leftArm).joint.gameObject.GetComponent<CapsuleCollider>(), GetSpringByJointType(JointType.hips).joint.gameObject.GetComponent<BoxCollider>(), true);
            Physics.IgnoreCollision(GetSpringByJointType(JointType.rightArm).joint.gameObject.GetComponent<CapsuleCollider>(), GetSpringByJointType(JointType.hips).joint.gameObject.GetComponent<BoxCollider>(), true);
            Physics.IgnoreCollision(GetSpringByJointType(JointType.leftThigh).joint.gameObject.GetComponent<CapsuleCollider>(), GetSpringByJointType(JointType.hips).joint.gameObject.GetComponent<BoxCollider>(), true);
            Physics.IgnoreCollision(GetSpringByJointType(JointType.rightThigh).joint.gameObject.GetComponent<CapsuleCollider>(), GetSpringByJointType(JointType.hips).joint.gameObject.GetComponent<BoxCollider>(), true);
            Physics.IgnoreCollision(GetSpringByJointType(JointType.leftKnee).joint.gameObject.GetComponent<CapsuleCollider>(), GetSpringByJointType(JointType.leftFoot).joint.gameObject.GetComponentInChildren<CapsuleCollider>(), true);
            Physics.IgnoreCollision(GetSpringByJointType(JointType.rightKnee).joint.gameObject.GetComponent<CapsuleCollider>(), GetSpringByJointType(JointType.rightFoot).joint.gameObject.GetComponentInChildren<CapsuleCollider>(), true);
            Physics.IgnoreCollision(GetSpringByJointType(JointType.leftThigh).joint.gameObject.GetComponent<CapsuleCollider>(), GetSpringByJointType(JointType.rightThigh).joint.gameObject.GetComponent<CapsuleCollider>(), true);
            Physics.IgnoreCollision(GetSpringByJointType(JointType.leftThigh).joint.gameObject.GetComponent<CapsuleCollider>(), GetSpringByJointType(JointType.rightKnee).joint.gameObject.GetComponent<CapsuleCollider>(), true);
            Physics.IgnoreCollision(GetSpringByJointType(JointType.leftThigh).joint.gameObject.GetComponent<CapsuleCollider>(), GetSpringByJointType(JointType.rightFoot).joint.gameObject.GetComponentInChildren<CapsuleCollider>(), true);
            Physics.IgnoreCollision(GetSpringByJointType(JointType.rightThigh).joint.gameObject.GetComponent<CapsuleCollider>(), GetSpringByJointType(JointType.leftKnee).joint.gameObject.GetComponent<CapsuleCollider>(), true);
            Physics.IgnoreCollision(GetSpringByJointType(JointType.rightThigh).joint.gameObject.GetComponent<CapsuleCollider>(), GetSpringByJointType(JointType.leftFoot).joint.gameObject.GetComponentInChildren<CapsuleCollider>(), true);
            Physics.IgnoreCollision(GetSpringByJointType(JointType.rightFoot).joint.gameObject.GetComponentInChildren<CapsuleCollider>(), GetSpringByJointType(JointType.leftFoot).joint.gameObject.GetComponentInChildren<CapsuleCollider>(), true);
            Physics.IgnoreCollision(GetSpringByJointType(JointType.rightFoot).joint.gameObject.GetComponentInChildren<CapsuleCollider>(), GetSpringByJointType(JointType.leftKnee).joint.gameObject.GetComponent<CapsuleCollider>(), true);
            Physics.IgnoreCollision(GetSpringByJointType(JointType.leftFoot).joint.gameObject.GetComponentInChildren<CapsuleCollider>(), GetSpringByJointType(JointType.rightKnee).joint.gameObject.GetComponent<CapsuleCollider>(), true);
            Physics.IgnoreCollision(GetSpringByJointType(JointType.leftKnee).joint.gameObject.GetComponent<CapsuleCollider>(), GetSpringByJointType(JointType.rightKnee).joint.gameObject.GetComponent<CapsuleCollider>(), true);

        }
    }

}
